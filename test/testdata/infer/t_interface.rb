# typed: strict
extend T::Sig

module MyInterface
  extend T::Sig
  extend T::Helpers
  interface!

  sig { abstract.returns(String) }
  def get_name; end
end

module AnotherInterface
  extend T::Sig
  extend T::Helpers
  interface!

  sig { abstract.returns(Integer) }
  def get_value; end
end

class MyClass
  extend T::Sig
  include MyInterface

  sig { override.returns(String) }
  def get_name
    "MyClass"
  end
end

# Test 1: Generic method with T::Interface (parallel to T::Class)
sig do
  type_parameters(:T)
    .params(type: T::Interface[T.type_parameter(:T)])
    .returns(T.type_parameter(:T))
end
def get_instance(type:)
  # In reality, this would get an instance from a container
  T.unsafe(nil)
end

instance = get_instance(type: MyInterface)
T.reveal_type(instance) # error: `MyInterface`

# Test 2: Concrete interface type
sig { params(interface_type: T::Interface[MyInterface]).returns(MyInterface) }
def create_from_interface(interface_type:)
  T.unsafe(nil)
end

result = create_from_interface(interface_type: MyInterface)
T.reveal_type(result) # error: `MyInterface`

# Test 3: Should work with multiple different interfaces
instance1 = get_instance(type: MyInterface)
instance2 = get_instance(type: AnotherInterface)
T.reveal_type(instance1) # error: `MyInterface`
T.reveal_type(instance2) # error: `AnotherInterface`

# Test 4: Should reject non-modules (classes)
get_instance(type: MyClass)
#                  ^^^^^^^ error: Expected `T::Interface[T.type_parameter(:T)]` but found `T.class_of(MyClass)` for argument `type`

# Test 5: Should reject non-module built-in types like String
sig { params(x: T::Interface[String]).void }
def takes_string_interface(x); end

takes_string_interface(String)
#                      ^^^^^^ error: Expected `T::Interface[String]` but found `T.class_of(String)` for argument `x`

# Test 6: T::Interface[...].new should error (can't instantiate the type)
# error-with-dupes: This code is unreachable
x = T::Interface[MyInterface].new
#                              ^^^ error: mistakes a type for a value

