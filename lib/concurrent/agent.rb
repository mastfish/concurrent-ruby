require 'thread'

require 'concurrent/dereferenceable'
require 'concurrent/observable'
require 'concurrent/options_parser'
require 'concurrent/utility/timeout'
require 'concurrent/logging'

module Concurrent

  # An agent is a single atomic value that represents an identity. The current value
  # of the agent can be requested at any time (`#deref`). Each agent has a work queue and operates on
  # the global thread pool. Consumers can `#post` code blocks to the agent. The code block (function)
  # will receive the current value of the agent as its sole parameter. The return value of the block
  # will become the new value of the agent. Agents support two error handling modes: fail and continue.
  # A good example of an agent is a shared incrementing counter, such as the score in a video game.
  #
  # @example Basic usage
  #   score = Concurrent::Agent.new(10)
  #   score.value #=> 10
  #   
  #   score << proc{|current| current + 100 }
  #   sleep(0.1)
  #   score.value #=> 110
  #   
  #   score << proc{|current| current * 2 }
  #   sleep(0.1)
  #   score.value #=> 220
  #   
  #   score << proc{|current| current - 50 }
  #   sleep(0.1)
  #   score.value #=> 170
  #
  # @!attribute [r] timeout
  #   @return [Fixnum] the maximum number of seconds before an update is cancelled
  class Agent
    include Dereferenceable
    include Concurrent::Observable
    include Logging

    # The default timeout value (in seconds); used when no timeout option
    # is given at initialization
    TIMEOUT = 5

    attr_reader :timeout, :task_executor, :operation_executor

    # Initialize a new Agent with the given initial value and provided options.
    #
    # @param [Object] initial the initial value
    # @param [Hash] opts the options used to define the behavior at update and deref
    #
    # @option opts [Fixnum] :timeout (TIMEOUT) maximum number of seconds before an update is cancelled
    #
    # @option opts [Boolean] :operation (false) when `true` will execute the future on the global
    #   operation pool (for long-running operations), when `false` will execute the future on the
    #   global task pool (for short-running tasks)
    # @option opts [object] :executor when provided will run all operations on
    #   this executor rather than the global thread pool (overrides :operation)
    #
    # @option opts [String] :dup_on_deref (false) call `#dup` before returning the data
    # @option opts [String] :freeze_on_deref (false) call `#freeze` before returning the data
    # @option opts [String] :copy_on_deref (nil) call the given `Proc` passing the internal value and
    #   returning the value returned from the proc
    def initialize(initial, opts = {})
      @value                = initial
      @rescuers             = []
      @validator            = Proc.new { |result| true }
      @timeout              = opts.fetch(:timeout, TIMEOUT).freeze
      self.observers        = CopyOnWriteObserverSet.new
      @serialized_execution = SerializedExecution.new
      @task_executor        = OptionsParser.get_task_executor_from(opts)
      @operation_executor   = OptionsParser.get_operation_executor_from(opts)
      init_mutex
      set_deref_options(opts)
    end

    # Specifies a block operation to be performed when an update operation raises
    # an exception. Rescue blocks will be checked in order they were added. The first
    # block for which the raised exception "is-a" subclass of the given `clazz` will
    # be called. If no `clazz` is given the block will match any caught exception.
    # This behavior is intended to be identical to Ruby's `begin/rescue/end` behavior.
    # Any number of rescue handlers can be added. If no rescue handlers are added then
    # caught exceptions will be suppressed.
    #
    # @param [Exception] clazz the class of exception to catch
    # @yield the block to be called when a matching exception is caught
    # @yieldparam [StandardError] ex the caught exception
    #
    # @example
    #   score = Concurrent::Agent.new(0).
    #             rescue(NoMethodError){|ex| puts "Bam!" }.
    #             rescue(ArgumentError){|ex| puts "Pow!" }.
    #             rescue{|ex| puts "Boom!" }
    #   
    #   score << proc{|current| raise ArgumentError }
    #   sleep(0.1)
    #   #=> puts "Pow!"
    def rescue(clazz = StandardError, &block)
      unless block.nil?
        mutex.synchronize do
          @rescuers << Rescuer.new(clazz, block)
        end
      end
      self
    end
    alias_method :catch, :rescue
    alias_method :on_error, :rescue

    # A block operation to be performed after every update to validate if the new
    # value is valid. If the new value is not valid then the current value is not
    # updated. If no validator is provided then all updates are considered valid.
    #
    # @yield the block to be called after every update operation to determine if
    #   the result is valid
    # @yieldparam [Object] value the result of the last update operation
    # @yieldreturn [Boolean] true if the value is valid else false
    def validate(&block)

      unless block.nil?
        begin
          mutex.lock
          @validator = block
        ensure
          mutex.unlock
        end
      end
      self
    end
    alias_method :validates, :validate
    alias_method :validate_with, :validate
    alias_method :validates_with, :validate

    # Update the current value with the result of the given block operation,
    # block should not do blocking calls, use #post_off for blocking calls
    #
    # @yield the operation to be performed with the current value in order to calculate
    #   the new value
    # @yieldparam [Object] value the current value
    # @yieldreturn [Object] the new value
    # @return [true, nil] nil when no block is given
    def post(&block)
      post_on(@task_executor, &block)
    end

    # Update the current value with the result of the given block operation,
    # block can do blocking calls
    #
    # @yield the operation to be performed with the current value in order to calculate
    #   the new value
    # @yieldparam [Object] value the current value
    # @yieldreturn [Object] the new value
    # @return [true, nil] nil when no block is given
    def post_off(&block)
      post_on(@operation_executor, &block)
    end

    # Update the current value with the result of the given block operation,
    # block should not do blocking calls, use #post_off for blocking calls
    #
    # @yield the operation to be performed with the current value in order to calculate
    #   the new value
    # @yieldparam [Object] value the current value
    # @yieldreturn [Object] the new value
    def <<(block)
      post(&block)
      self
    end

    # Waits/blocks until all the updates sent before this call are done.
    #
    # @param [Numeric] timeout the maximum time in second to wait.
    # @return [Boolean] false on timeout, true otherwise
    def await(timeout = nil)
      done = Event.new
      post { |val| done.set; val }
      done.wait timeout
    end

    private

    def post_on(executor, &block)
      return nil if block.nil?
      @serialized_execution.post(executor) { work(&block) }
      true
    end

    # @!visibility private
    Rescuer = Struct.new(:clazz, :block) # :nodoc:

    # @!visibility private
    def try_rescue(ex) # :nodoc:
      rescuer = mutex.synchronize do
        @rescuers.find { |r| ex.is_a?(r.clazz) }
      end
      rescuer.block.call(ex) if rescuer
    rescue Exception => ex
      # suppress
      log DEBUG, ex
    end

    # @!visibility private
    def work(&handler) # :nodoc:
      validator, value = mutex.synchronize { [@validator, @value] }

      begin
        result, valid = Concurrent::timeout(@timeout) do
          result = handler.call(value)
          [result, validator.call(result)]
        end
      rescue Exception => ex
        exception = ex
      end

      begin
        mutex.lock
        should_notify = if !exception && valid
                          @value = result
                          true
                        end
      ensure
        mutex.unlock
      end

      if should_notify
        time = Time.now
        observers.notify_observers { [time, self.value] }
      end

      try_rescue(exception)
    end
  end
end
