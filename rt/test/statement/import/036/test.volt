//T macro:importfail
//T check:access
module test;

import b36;

fn main() i32
{
	*pointer += 3;
	return *pointer - 7;
}
