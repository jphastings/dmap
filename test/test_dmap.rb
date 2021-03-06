require 'helper'

class TestDmap < Test::Unit::TestCase
  context "The parser" do
    should "accept a string tag" do
      assert_nothing_raised do
        DMAP::Element.new("minm","An Item's Name")
      end
    end
    
    should "accept a dmap string" do
      assert_nothing_raised do
        DMAP::Element.new(StringIO.new("minm   A Thirty Byte String, yes yes!"))
      end
    end
    
    should "throw a wobbly when it doesn't recognise the tag" do
      assert_raise NameError do
        DMAP::Element.new("xxxx")
      end
    end
  end
end
