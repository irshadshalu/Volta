// Copyright 2013-2017, Jakob Bornecrantz.
// SPDX-License-Identifier: BSL-1.0
// Written by hand from documentation.
module vrt.ext.dwarf;

version (CRuntime_All):

import core.rt.misc: vrt_panic;
import vrt.ext.stdc: uintptr_t;


struct DW_Context
{
	textrel: void*;
	datarel: void*;
	funcrel: void*;
}

enum {
	DW_EH_PE_omit    = 0xff, // value is not present

	// value format
	DW_EH_PE_absptr  = 0x00,
	DW_EH_PE_uleb128 = 0x01,
	DW_EH_PE_udata2  = 0x02, // unsigned 2-byte
	DW_EH_PE_udata4  = 0x03,
	DW_EH_PE_udata8  = 0x04,
	DW_EH_PE_sleb128 = 0x09,
	DW_EH_PE_sdata2  = 0x0a,
	DW_EH_PE_sdata4  = 0x0b,
	DW_EH_PE_sdata8  = 0x0c,

	// value meaning
	DW_EH_PE_pcrel    = 0x10, // relative to program counter
	DW_EH_PE_textrel  = 0x20, // relative to .text
	DW_EH_PE_datarel  = 0x30, // relative to .got or .eh_frame_hdr
	DW_EH_PE_funcrel  = 0x40, // relative to beginning of function
	DW_EH_PE_aligned  = 0x50, // is an aligned void*

	// value is a pointer to the actual value
	// this is a mask on top of one of the above
	DW_EH_PE_indirect = 0x80
}

fn dw_read_uleb128(data: const(u8)**) uintptr_t
{
	result: uintptr_t;
	shift: uintptr_t;
	b: u8;
	p := *data;

	do {
		b = *p++;
		result |= cast(uintptr_t)(b & 0x7f) << shift;
		shift += 7;
	} while (b & 0x80);

	*data = p;

	return result;
}

static fn dw_read_sleb128(data: const(u8)**) uintptr_t
{
	result: uintptr_t;
	shift: uintptr_t;
	b: u8;
	p := *data;

	do {
		b = *p++;
		result |= cast(uintptr_t)(b & 0x7f) << shift;
		shift += 7;
	} while (b & 0x80);

	*data = p;

	if ((b & 0x40) != 0 && (shift < typeid(uintptr_t).size * 8)) {
		result |= (cast(uintptr_t)-1 << shift);
	}

	return result;
}

fn dw_read_ubyte(data: const(u8)**) u8
{
	p := *data;
	result := cast(u8)*p++;
	*data = p;
	return result;
}

fn dw_encoded_size(encoding: u8) size_t
{
	switch (encoding & 0x0F) {
	case DW_EH_PE_absptr:
		return typeid(void*).size;
	case DW_EH_PE_udata2:
		return typeid(u16).size;
	case DW_EH_PE_udata4:
		return typeid(u32).size;
	case DW_EH_PE_udata8:
		return typeid(u64).size;
	case DW_EH_PE_sdata2:
		return typeid(i16).size;
	case DW_EH_PE_sdata4:
		return typeid(i32).size;
	case DW_EH_PE_sdata8:
		return typeid(i64).size;
	default:
		msgs: char[][1];
		msgs[0] = cast(char[])"unhandled case";
		vrt_panic(cast(char[][])msgs);
		break;
	}
	assert(false); // To please cfg detection
}

fn dw_read_encoded(data: const(u8)**, encoding: u8) uintptr_t
{
	result: uintptr_t;
	pc := *data;
	p := *data;

	switch (encoding & 0x0F) {
	case DW_EH_PE_uleb128:
		result = dw_read_uleb128(&p);
		break;
	case DW_EH_PE_sleb128:
		result = dw_read_sleb128(&p);
		break;
	case DW_EH_PE_absptr:
		result = *(cast(uintptr_t*)p);
		p += typeid(uintptr_t).size;
		break;
	case DW_EH_PE_udata2:
		result = *(cast(ushort*)p);
		p += typeid(ushort).size;
		break;
	case DW_EH_PE_udata4:
		result = *(cast(uint*)p);
		p += typeid(uint).size;
		break;
	case DW_EH_PE_udata8:
		result = cast(uintptr_t)*(cast(ulong*)p);
		p += typeid(ulong).size;
		break;
	case DW_EH_PE_sdata2:
		result = cast(uintptr_t)*(cast(short*)p);
		p += typeid(short).size;
		break;
	case DW_EH_PE_sdata4:
		result = cast(uintptr_t)*(cast(int*)p);
		p += typeid(int).size;
		break;
	case DW_EH_PE_sdata8:
		result = cast(uintptr_t)*(cast(long*)p);
		p += typeid(long).size;
		break;
	default:
		msgs: char[][1];
		msgs[0] = cast(char[])"unhandled case type";
		vrt_panic(cast(char[][])msgs);
		break;
	}

	if (result) {
		switch (encoding & 0x70) {
		case DW_EH_PE_absptr:
			break;
		case DW_EH_PE_pcrel:
			result += cast(uintptr_t)pc;
			break;
		default:
			msgs: char[][1];
			msgs[0] = cast(char[])"unhandled case type";
			vrt_panic(cast(char[][])msgs);
			break;
		}

		if (encoding & DW_EH_PE_indirect)
			result = *cast(uintptr_t*)result;
	}

	*data = p;

	return result;
}
