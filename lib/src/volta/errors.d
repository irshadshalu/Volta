/*#D*/
// Copyright 2013-2017, Bernard Helyer.
// Copyright 2013-2017, Jakob Bornecrantz.
// SPDX-License-Identifier: BSL-1.0
module volta.errors;

import watt.io.std;
import watt.text.format : format;  // @todo if this isn't specified, we get a lookup bug.

import ir = volta.ir;

import volta.interfaces;
import volta.settings;
import volta.ir.location;

public import volta.util.errormessages;


/*
 *
 * Panics
 *
 */

void panic(ErrorSink es, string message, string file = __FILE__, int line = __LINE__)
{
	es.onPanic(message, file, line);
}

void panic(ErrorSink es, ref in Location loc, string message, string file = __FILE__, int line = __LINE__)
{
	es.onPanic(/*#ref*/loc, message, file, line);
}

void panic(ErrorSink es, ir.Node n, string message, string file = __FILE__, int line = __LINE__)
{
	es.panic(/*#ref*/n.loc, message, file, line);
}

bool passert(ErrorSink es, ir.Node n, bool condition, string file = __FILE__, int line = __LINE__)
{
	if (!condition) {
		panic(es, "passert failure", file, line);
	}
	return condition;
}


/*
 *
 * Errors
 *
 */

void errorMsg(ErrorSink es, ref in Location loc, string message, string file = __FILE__, int line = __LINE__)
{
	es.onError(/*#ref*/loc, message, file, line);
}

void errorMsg(ErrorSink es, ir.Node n, string message, string file = __FILE__, int line = __LINE__)
{
	es.errorMsg(/*#ref*/n.loc, message, file, line);
}

void errorExpected(ErrorSink es, ref in Location loc, string expected, string file = __FILE__, int line = __LINE__)
{
	es.onError(/*#ref*/loc, format("expected %s.", expected), file, line);
}

void errorExpected(ErrorSink es, ir.Node n, string expected, string file = __FILE__, int line = __LINE__)
{
	es.errorExpected(/*#ref*/n.loc, expected, file, line);
}

void errorRedefine(ErrorSink es, ref in Location newDef, ref in Location oldDef, string name,
				   string file = __FILE__, int line = __LINE__)
{
	auto msg = format("symbol '%s' redefinition. First defined @ %s.", name, oldDef.toString());
	es.onError(/*#ref*/newDef, msg, file, line);
}

/*
 *
 * Warnings
 *
 */

void warning(ref in Location loc, string message)
{
	error.writefln(format("%s: warning: %s", loc.toString(), message));
}

void warning(ErrorSink es, ref in Location loc, string message, string file = __FILE__, int line = __LINE__)
{
	es.onWarning(/*#ref*/loc, message, file, line);
}

void warning(ErrorSink es, ir.Node n, string message, string file = __FILE__, int line = __LINE__)
{
	es.warning(/*#ref*/n.loc, message, file, line);
}

void warningAssignToSelf(ref in Location loc, string name, bool warningsEnabled)
{
	if (warningsEnabled) {
		warning(/*#ref*/loc, format("assigning %s to itself, expression has no effect.", name));
	}
}

void warningOldStyleVariable(ref in Location loc, bool magicFlagD, Settings settings)
{
	if (!magicFlagD && settings.warningsEnabled) {
		warning(/*#ref*/loc, "old style variable declaration.");
	}
}

void warningOldStyleFunction(ref in Location loc, bool magicFlagD, Settings settings)
{
	if (!magicFlagD && settings.warningsEnabled) {
		warning(/*#ref*/loc, "old style function declaration.");
	}
}

void warningOldStyleFunctionPtr(ref in Location loc, bool magicFlagD, Settings settings)
{
	if (!magicFlagD && settings.warningsEnabled) {
		warning(/*#ref*/loc, "old style function pointer.");
	}
}

void warningOldStyleDelegateType(ref in Location loc, bool magicFlagD, Settings settings)
{
	if (!magicFlagD && settings.warningsEnabled) {
		warning(/*#ref*/loc, "old style delegate type.");
	}
}

void warningOldStyleHexTypeSuffix(ref in Location loc, bool magicFlagD, Settings settings)
{
	if (!magicFlagD && settings.warningsEnabled) {
		warning(/*#ref*/loc, "old style hex literal type suffix (U/L).");
	}
}

void warningShadowsField(ref in Location newDecl, ref in Location oldDecl, string name, bool warningsEnabled)
{
	if (warningsEnabled) {
		warning(/*#ref*/newDecl, format("declaration '%s' shadows field at %s.", name, oldDecl.toString()));
	}
}
