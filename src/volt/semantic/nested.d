// Copyright © 2013-2015, Bernard Helyer.  All rights reserved.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module volt.semantic.nested;

import watt.conv : toString;

import ir = volt.ir.ir;
import volt.ir.copy;
import volt.ir.util;

import volt.errors;

import volt.interfaces;
import volt.semantic.util;
import volt.semantic.lookup : getModuleFromScope;
import volt.semantic.context;
import volt.semantic.classify : isNested;


void emitNestedStructs(ir.Function parentFunction, ir.BlockStatement bs, ref ir.Struct[] structs)
{
	for (size_t i = 0; i < bs.statements.length; ++i) {
		auto fn = cast(ir.Function) bs.statements[i];
		if (fn is null) {
			continue;
		}
		if (fn.suffix.length == 0) {
			foreach (existingFn; parentFunction.nestedFunctions) {
				if (fn.name == existingFn.oldname) {
					throw makeCannotOverloadNested(fn, fn);
				}
			}
			parentFunction.nestedFunctions ~= fn;
			fn.suffix = toString(getModuleFromScope(parentFunction.location, parentFunction._body.myScope).getId());
		}
		if (parentFunction.nestStruct is null) {
			parentFunction.nestStruct = createAndAddNestedStruct(parentFunction, parentFunction._body);
			structs ~= parentFunction.nestStruct;
		}
		emitNestedStructs(parentFunction, fn._body, structs);
	}
}

ir.Struct createAndAddNestedStruct(ir.Function fn, ir.BlockStatement bs)
{
	auto s = buildStruct(fn.location, "__Nested" ~ toString(cast(void*)fn), []);
	auto decl = buildVariable(fn.location, buildTypeReference(s.location, s, "__Nested"), ir.Variable.Storage.Function, "__nested");
	decl.isResolved = true;
	fn.nestedVariable = decl;
	bs.statements = s ~ (decl ~ bs.statements);
	return s;
}

bool replaceNested(ref ir.Exp exp, ir.ExpReference eref, ir.Variable nestParam)
{
	if (eref.doNotRewriteAsNestedLookup) {
		return false;
	}
	string name;
	ir.Type type;

	auto fp = cast(ir.FunctionParam) eref.decl;
	if (fp is null || !fp.hasBeenNested) {
		auto var = cast(ir.Variable) eref.decl;
		if (var is null || !isNested(var.storage)) {
			return false;
		} else {
			name = var.name;
			type = var.type;
		}
	} else {
		name = fp.name;
		type = fp.type;
	}
	assert(name.length > 0);

	if (nestParam is null) {
		return false;
	}
	exp = buildAccess(exp.location, buildExpReference(nestParam.location, nestParam, nestParam.name), name);
	if (fp !is null &&
	    (fp.fn.type.isArgRef[fp.index] ||
	     fp.fn.type.isArgOut[fp.index])) {
		exp = buildDeref(exp.location, exp);
	}
	return true;
}

void insertBinOpAssignsForNestedVariableAssigns(LanguagePass lp, ir.BlockStatement bs)
{
	for (size_t i = 0; i < bs.statements.length; ++i) {
		auto var = cast(ir.Variable) bs.statements[i];
		if (var is null ||
		    !isNested(var.storage)) {
			continue;
		}

		version (none) {
			bs.statements = bs.statements[0 .. i] ~ bs.statements[i + 1 .. $];
			i--;
		}

		ir.Exp value;
		if (var.assign is null) {
			value = getDefaultInit(var.location, lp, var.type);
		} else {
			value = var.assign;
		}

		auto eref = buildExpReference(var.location, var, var.name);
		auto assign = buildAssign(var.location, eref, value);
		bs.statements[i] = buildExpStat(assign.location, assign);
	}
}

void tagNestedVariables(Context ctx, ir.Variable var, ir.Store store, ref ir.Exp e)
{
	if (!ctx.isFunction ||
	    ctx.currentFunction.nestStruct is null) {
		return;
	}

	if (ctx.current.nestedDepth <= store.parent.nestedDepth) {
		return;
	}

	assert(ctx.currentFunction.nestStruct !is null);
	if (var.storage != ir.Variable.Storage.Field &&
	    !isNested(var.storage)) {
		// If we're tagging a global variable, just ignore it.
		if (var.storage == ir.Variable.Storage.Local ||
		    var.storage == ir.Variable.Storage.Global) {
			return;
		}

		var.storage = ir.Variable.Storage.Nested;

		// Skip adding this variables to nested struct.
		if (var.name == "this") {
			return;
		}
		addVarToStructSmart(ctx.currentFunction.nestStruct, var);
	} else if (var.storage == ir.Variable.Storage.Field) {
		if (ctx.currentFunction.nestedHiddenParameter is null) {
			return;
		}
		auto nref = buildExpReference(var.location, ctx.currentFunction.nestedHiddenParameter, ctx.currentFunction.nestedHiddenParameter.name);
		auto a = buildAccess(var.location, nref, "this");
		e = buildAccess(a.location, a, var.name);
	}
}

/**
 * Make eref a CreateDelegate to the nested struct.
 * If the housing function (fn) and declaration the eref is referring to don't match,
 * then this is just like a call to buildCreateDelegate.
 * Otherwise, it's a recursive reference, and a unique nesting struct is created for it.
 */
ir.Exp buildNestedReference(ir.Location loc, ir.Function fn, ir.Variable np, ir.ExpReference eref) {
	if (fn !is eref.decl) {
		// The function housing the reference is not the same as the reference, i.e. not recursive.
		return buildCreateDelegate(loc, buildExpReference(np.location, np, np.name), eref);
	}
	/* This is a recursive reference. Give it its own nested struct so if it's a call, the original parameters
	 * are not modified.
	 */
	auto sexp = buildStatementExp(loc);
	auto newNested = buildVariableAnonSmart(loc, fn._body, sexp, fn.nestStruct, buildExpReference(loc, fn.nestedHiddenParameter, fn.nestedHiddenParameter.name));
	auto callexp = buildCreateDelegate(loc, buildExpReference(loc, newNested, newNested.name), eref);
	buildExpStat(loc, sexp, callexp);
	sexp.exp = callexp;
	return sexp;
}