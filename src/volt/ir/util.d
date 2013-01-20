// Copyright © 2013, Jakob Bornecrantz.  All rights reserved.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module volt.ir.util;

import volt.token.location;
import ir = volt.ir.ir;


/**
 * Return the scope from the given type if it is,
 * a aggregate or a derivative from one.
 */
ir.Scope getScopeFromType(ir.Type type)
{
	switch (type.nodeType) with (ir.NodeType) {
	case TypeReference:
		auto asTypeRef = cast(ir.TypeReference) type;
		assert(asTypeRef !is null);
		assert(asTypeRef.type !is null);
		return getScopeFromType(asTypeRef.type);
	case ArrayType:
		auto asArray = cast(ir.ArrayType) type;
		assert(asArray !is null);
		return getScopeFromType(asArray.base);
	case PointerType:
		auto asPointer = cast(ir.PointerType) type;
		assert(asPointer !is null);
		return getScopeFromType(asPointer.base);
	case Struct:
		auto asStruct = cast(ir.Struct) type;
		assert(asStruct !is null);
		return asStruct.myScope;
	case Class:
		auto asClass = cast(ir.Class) type;
		assert(asClass !is null);
		return asClass.myScope;
	case Interface:
		auto asInterface = cast(ir._Interface) type;
		assert(asInterface !is null);
		return asInterface.myScope;
	default:
		return null;
	}
}

/**
 * For the give store get the scoep that it introduces.
 *
 * Returns null for Values and non-scope types.
 */
ir.Scope getScopeFromStore(ir.Store store)
{
	final switch(store.kind) with (ir.Store.Kind) {
	case Scope:
		return store.s;
	case Type:
		auto type = cast(ir.Type)store.node;
		assert(type !is null);
		return getScopeFromType(type);
	case Value:
	case Function:
		return null;
	}
}

/**
 * Does a smart copy of a type.
 *
 * Meaning that well copy all types, but skipping
 * TypeReferences, but inserting one when it comes
 * across a named type.
 */
ir.Type copyTypeSmart(ir.Type type, Location loc)
{
	switch (type.nodeType) with (ir.NodeType) {
	case PrimitiveType:
		auto pt = cast(ir.PrimitiveType)type;
		pt.location = loc;
		pt = new ir.PrimitiveType(pt.type);
		return pt;
	case PointerType:
		auto pt = cast(ir.PointerType)type;
		pt.location = loc;
		pt = new ir.PointerType(copyTypeSmart(pt.base, loc));
		return pt;
	case ArrayType:
		auto at = cast(ir.ArrayType)type;
		at.location = loc;
		at = new ir.ArrayType(copyTypeSmart(at.base, loc));
		return at;
	case StaticArrayType:
		auto asSat = cast(ir.StaticArrayType)type;
		auto sat = new ir.StaticArrayType();
		sat.location = loc;
		sat.base = copyTypeSmart(asSat.base, loc);
		sat.length = asSat.length;
		return sat;
	case AAType:
		auto asAA = cast(ir.AAType)type;
		auto aa = new ir.AAType();
		aa.location = loc;
		aa.value = copyTypeSmart(asAA.value, loc);
		aa.key = copyTypeSmart(asAA.key, loc);
		return aa;
	case FunctionType:
		auto asFt = cast(ir.FunctionType)type;
		auto ft = new ir.FunctionType(asFt);
		ft.location = loc;
		ft.ret = copyTypeSmart(ft.ret, loc);
		foreach(ref var; ft.params) {
			auto t = copyTypeSmart(var.type, loc);
			var = new ir.Variable();
			var.location = loc;
			var.type = t;
		}
		return ft;
	case DelegateType:
		auto asDg = cast(ir.DelegateType)type;
		auto dg = new ir.DelegateType(asDg);
		dg.location = loc;
		dg.ret = copyTypeSmart(dg.ret, loc);
		foreach(ref var; dg.params) {
			auto t = copyTypeSmart(var.type, loc);
			var = new ir.Variable();
			var.location = loc;
			var.type = t;
		}
		return dg;
	case StorageType:
		auto asSt = cast(ir.StorageType)type;
		auto st = new ir.StorageType();
		st.location = loc;
		st.base = copyTypeSmart(asSt.base, loc);
		st.type = asSt.type;
		return st;
	case TypeReference:
		auto tr = cast(ir.TypeReference)type;
		return copyTypeSmart(tr.type, loc);
	case Interface:
	case Struct:
	case Class:
	case Enum:
		auto s = getScopeFromType(type);
		auto tr = new ir.TypeReference(type, null);
		tr.location = loc;
		/// @todo Get fully qualified name for type.
		if (s !is null)
			tr.names = [s.name];
		return tr;
	default:
		assert(false);
	}
}

/**
 * Builds a usable ExpReference.
 */
ir.ExpReference buildExpReference(ir.Declaration decl, string[] names, Location loc)
{
	auto varRef = new ir.ExpReference();
	varRef.location = loc;
	varRef.decl = decl;
	varRef.idents ~= names;

	return varRef;
}

/**
 * Build a cast but setting location to exps location and
 * calling copyTypeSmart on the type, to avoid duplicate nodes.
 */
ir.Unary buildCastSmart(ir.Type type, ir.Exp exp)
{
	return buildCastSmart(type, exp, exp.location);
}

/**
 * Build a cast but setting location and calling copyTypeSmart
 * on the type, to avoid duplicate nodes.
 */
ir.Unary buildCastSmart(ir.Type type, ir.Exp exp, Location location)
{
	auto cst = new ir.Unary(copyTypeSmart(type, location), exp);
	cst.location = location;
	return cst;
}

/**
 * Build a cast to bool setting location to the exp location.
 */
ir.Unary buildCastToBool(ir.Exp exp)
{
	auto pt = new ir.PrimitiveType(ir.PrimitiveType.Kind.Bool);
	pt.location = exp.location;

	auto cst = new ir.Unary(pt, exp);
	cst.location = exp.location;
	return cst;
}

/**
 * Builds a completely useable struct and insert it into the
 * various places it needs to be inserted.
 */
ir.Struct buildStruct(ir.TopLevelBlock tlb, ir.Scope _scope, string name, Location loc)
{
	auto s = new ir.Struct();
	s.name = name;
	s.myScope = new ir.Scope(_scope, s, name);
	s.location = loc;

	s.members = new ir.TopLevelBlock();
	s.members.location = loc;

	// Insert the struct into all the places.
	_scope.addType(s, s.name);
	tlb.nodes ~= s;
	return s;
}
