//T macro:expect-failure
// Test for failure on final switch over non enum type.
module test;

fn main() i32
{
	final switch (2) {
	case 1:
		return 1;
	case 2:
		return 5;
	case 3:
		return 7;
	}
}
