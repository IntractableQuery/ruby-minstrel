# Wrap method calls for a class of your choosing.
# Example:
# instrument = Minstrel::Instrument.new()
# instrument.wrap(String) do |point, klass, method, *args|
#   ...
# end
#
#  * point is either :enter or :exit depending if this function is about to be
#    called or has finished being called.
#  * klass is the class object (String, etc)
#  * method is the method (a Symbol)
#  * *args is the arguments passed
#
# You can also wrap from the command-line
#
# RUBY_INSTRUMENT=comma_separated_classnames ruby -rminstrel ./your/program.rb
#

require "set"

module Minstrel; class Instrument
  attr_accessor :counter

  class << self
    @@deferred_wraps = {}
    @@wrapped = Set.new
  end

  # Put methods we must not be wrapping here.
  DONOTWRAP = {
    "Minstrel::Instrument" => Minstrel::Instrument.methods.collect { |m| m.to_sym },
    "Object" => [ :to_sym, :respond_to?, :send, :java_send, :method, :java_method ],
    "Class" => [ :to_s ],
  }

  # Wrap a class's instance methods with your block.
  # The block will be called with 4 arguments, and called
  # before and after the original method.
  # Arguments:
  #   * point - the point (symbol, :entry or :exit) of call,
  #   * klass - the class (object) owning this method
  #   * method - the method (symbol) being called
  #   * *args - the arguments (array) passed to this method.
  def wrap(klass, &block)
    return true if @@wrapped.include?(klass)
    instrumenter = self # save 'self' for scoping below
    p [klass, @@wrapped.include?(klass)]
    @@wrapped << klass

    klass.instance_methods.each do |method|
      method = method.to_sym

      # If we shouldn't wrap a certain class method, skip it.
      skip = false
      ancestors = klass.ancestors.collect {|k| k.to_s} 
      (ancestors & DONOTWRAP.keys).each do |key|
        if DONOTWRAP[key].include?(method)
          skip = true 
          break
        end
      end
      if skip
        puts "Skipping #{klass}##{method} (do not wrap)"
      end
      next if skip

      puts "Wrapping #{klass}##{method}"
      klass.class_eval do
        orig_method = "#{method}_original(wrapped)".to_sym
        orig_method_proc = klass.instance_method(method)
        alias_method orig_method, method
        #block.call(:wrap, klass, method)
        define_method(method) do |*args, &argblock|
          exception = false
          block.call(:enter, klass, method, *args)
          begin
            # TODO(sissel): Not sure which is better:
            # * UnboundMethod#bind(self).call(...)
            # * self.method(orig_method).call(...)
            val = orig_method_proc.bind(self).call(*args, &argblock)
            #m = self.method(orig_method)
            #val = m.call(*args, &argblock)
          rescue => e
            exception = e
          end
          if exception
            block.call(:exit_exception, klass, method, *args)
            raise e if exception
          else
            block.call(:exit, klass, method, *args)
          end
          return val
        end
      end # klass.class_eval
    end # klass.instance_methods.each

    klass.methods.each do |method|
      method = method.to_sym
      # If we shouldn't wrap a certain class method, skip it.
      skip = false
      ancestors = klass.ancestors.collect {|k| k.to_s} 
      (ancestors & DONOTWRAP.keys).each do |key|
        if DONOTWRAP[key].include?(method)
          skip = true 
          break
        end
      end
      if skip
        puts "Skipping #{klass}##{method} (do not wrap)"
      end
      next if skip

      klass.instance_eval do
        orig_method = "#{method}_original(classwrapped)".to_sym
        (class << self; self; end).instance_eval do
          begin
            alias_method orig_method, method.to_sym
          rescue NameError => e
            # No such method, strange but true.
            orig_method = self.method(method.to_sym)
          end
          method = method.to_sym
          define_method(method) do |*args, &argblock|
            block.call(:class_enter, klass, method, *args)
            exception = false
            begin
              if orig_method.is_a?(Symbol)
                val = send(orig_method, *args, &argblock)
              else
                val = orig_method.call(*args, &argblock)
              end
            rescue => e
              exception = e
            end
            if exception
              block.call(:class_exit_exception, klass, method, *args)
              raise e if exception
            else
              block.call(:class_exit, klass, method, *args)
            end
            return val
          end
        end
        #block.call(:class_wrap, klass, method, self.method(method))
      end # klass.class_eval
    end # klass.instance_methods.each

    return true
  end # def wrap

  def wrap_classname(klassname, &block)
    begin
      klass = eval(klassname)
      self.wrap(klass, &block) 
      return true
    rescue NameError => e
      @@deferred_wraps[klassname] = block
    end
    return false
  end

  def wrap_all(&block)
    @@deferred_wraps[:all] = block
    ObjectSpace.each_object do |obj|
      next unless obj.is_a?(Class)
      wrap(obj, &block)
    end
  end

  def self.wrap_require
    Kernel.class_eval do
      alias_method :old_require, :require
      def require(*args)
        return Minstrel::Instrument::instrumented_require(*args)
      end
    end
  end

  def self.instrumented_require(*args)
    ret = old_require(*args)
    if @@deferred_wraps.include?(:all)
      # try to wrap anything new that is not wrapped
      wrap_all(@@deferred_wraps[:all])
    else
      # look for deferred class wraps
      klasses = @@deferred_wraps.keys
      klasses.each do |klassname|
        if @@deferred_wraps.include?("ALL")
          all = true
        end
        block = @@deferred_wraps[klassname]
        instrument = Minstrel::Instrument.new
        if instrument.wrap_classname(klassname, &block)
          $stderr.puts "Wrap of #{klassname} successful"
          @@deferred_wraps.delete(klassname) if !all
        end
      end
    end
    return ret
  end
end; end # class Minstrel::Instrument

Minstrel::Instrument.wrap_require

# Provide a way to instrument a class using the command line:
# RUBY_INSTRUMENT=String ruby -rminstrel ./your/program
if ENV["RUBY_INSTRUMENT"]
  klasses = ENV["RUBY_INSTRUMENT"].split(",")
  if klasses.include?(":all:")
    instrument = Minstrel::Instrument.new 
    instrument.wrap_all do |point, klass, method, *args|
      puts "#{point} #{klass.to_s}##{method}(#{args.inspect})"
    end
  else
    klasses.each do |klassname|
      instrument = Minstrel::Instrument.new 
      instrument.wrap_classname(klassname) do |point, klass, method, *args|
        puts "#{point} #{klassname}##{method}(#{args.inspect})"
      end
    end
  end
end
