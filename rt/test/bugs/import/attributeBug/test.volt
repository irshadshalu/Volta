//T macro:import
module test;

import ol;

fn main() i32
{
	o: OVERLAPPED;
	o.Internal = 32;
	return o.Internal - 32;
}
