//T macro:expect-failure
//T check:to have same return type
module test;

struct TestStruct
{
	val: size_t;

	fn opSliceAssign(a: size_t, b: size_t, c: size_t)
	{
		val = c;
	}

	fn opSlice(a: size_t, b: size_t) i32
	{
		return cast(i32)(a + b + val);
	}
}

fn main() i32
{
	ts: TestStruct;
	ts[1 .. 6] = 13;
	return ts[1 .. 6];
}
