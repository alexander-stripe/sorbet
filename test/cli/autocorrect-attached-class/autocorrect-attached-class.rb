# typed: false

# ^ unavoidable (error emitted in typed false)

class A
  extend T::Sig
  sig {returns(T.experimental_attached_class)}
  def self.foo
    new
  end
end

class B
  extend T::Sig

  # Note that the autocorrect strips the :: and the () to avoid writing code
  # that reads the source file and see what was actually written originally.
  sig {returns(::T.experimental_attached_class())}
  def self.foo
    new
  end
end
