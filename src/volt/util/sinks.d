// Copyright © 2015-2016, Jakob Bornecrantz.  All rights reserved.
// See copyright notice in src/volt/licence.d (BOOST ver 1.0).
module volt.util.sinks;

import ir = volt.ir.ir;


/*
 * These creates arrays of types,
 * with minimal allocations. Declare on the stack.
 */

struct IntSink
{
public:
	/// The one true sink definition.
	alias Sink = void delegate(SinkArg);

	/// The argument to the one true sink.
	alias SinkArg = scope int[];

	enum size_t MinSize = 16;
	enum size_t MaxSize = 2048;

	@property size_t length()
	{
		return mLength;
	}

private:
	int[32] mStore;
	int[] mArr;
	size_t mLength;


public:
	void sink(int type)
	{
		auto newSize = mLength + 1;
		if (mArr.length == 0) {
			mArr = mStore[0 .. $];
		}

		if (newSize <= mArr.length) {
			mArr[mLength++] = type;
			return;
		}

		auto allocSize = mArr.length;
		while (allocSize < newSize) {
			if (allocSize >= MaxSize) {
				allocSize += MaxSize;
			} else {
				allocSize = allocSize * 2;
			}
		}

		auto n = new int[](allocSize);
		n[0 .. mLength] = mArr[0 .. mLength];
		n[mLength++] = type;
		mArr = n;
	}

	void popLast()
	{
		if (mLength > 0) {
			mLength--;
		}
	}

	int getLast()
	{
		return mArr[mLength - 1];
	}

	int get(size_t i)
	{
		return mArr[i];
	}

	void set(size_t i, int n)
	{
		mArr[i] = n;
	}

	void setLast(int i)
	{
		mArr[mLength - 1] = i;
	}

	/**
	 * Safely get the backing storage from the sink without copying.
	 */
	void toSink(Sink sink)
	{
		return sink(mArr[0 .. mLength]);
	}

	void reset()
	{
		mLength = 0;
	}
}

struct FunctionSink
{
public:
	/// The one true sink definition.
	alias Sink = void delegate(SinkArg);

	/// The argument to the one true sink.
	alias SinkArg = scope ir.Function[];

	enum size_t MinSize = 16;
	enum size_t MaxSize = 2048;

	@property size_t length()
	{
		return mLength;
	}

private:
	ir.Function[32] mStore;
	ir.Function[] mArr;
	size_t mLength;


public:
	void sink(ir.Function type)
	{
		auto newSize = mLength + 1;
		if (mArr.length == 0) {
			mArr = mStore[0 .. $];
		}

		if (newSize <= mArr.length) {
			mArr[mLength++] = type;
			return;
		}

		auto allocSize = mArr.length;
		while (allocSize < newSize) {
			if (allocSize >= MaxSize) {
				allocSize += MaxSize;
			} else {
				allocSize = allocSize * 2;
			}
		}

		auto n = new ir.Function[](allocSize);
		n[0 .. mLength] = mArr[0 .. mLength];
		n[mLength++] = type;
		mArr = n;
	}

	void popLast()
	{
		if (mLength > 0) {
			mLength--;
		}
	}

	ir.Function getLast()
	{
		return mArr[mLength - 1];
	}

	ir.Function get(size_t i)
	{
		return mArr[i];
	}

	void set(size_t i, ir.Function func)
	{
		mArr[i] = func;
	}

	void setLast(ir.Function i)
	{
		mArr[mLength - 1] = i;
	}

	/**
	 * Safely get the backing storage from the sink without copying.
	 */
	void toSink(Sink sink)
	{
		return sink(mArr[0 .. mLength]);
	}

	void reset()
	{
		mLength = 0;
	}
}