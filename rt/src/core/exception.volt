// Copyright © 2016, Jakob Bornecrantz.  All rights reserved.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module core.exception;


class Throwable
{
	string msg;

	// These two are updated each time the exception is thrown.
	string throwFile;
	size_t throwLine;

	// These are manually supplied
	string file;
	size_t line;

	this(string msg, string file = __FILE__, size_t line = __LINE__)
	{
		this.msg = msg;
		this.file = file;
		this.line = line;
	}
}

class Exception : Throwable
{
	this(string msg, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line);
	}
}

class Error : Throwable
{
	this(string msg, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line);
	}
}

class AssertError : Error
{
	this(string msg, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line);
	}
}

class MalformedUTF8Exception : Exception
{
	this(string msg = "malformed UTF-8 stream",
	     string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line);
	}
}

// Thrown if Key does not exist in AA
class KeyNotFoundException : Exception
{
	this(string msg)
	{
		super(msg);
	}
}