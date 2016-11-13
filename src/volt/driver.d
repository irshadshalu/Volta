// Copyright © 2012-2016, Jakob Bornecrantz.  All rights reserved.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module volt.driver;

import core.exception;

import io = watt.io.std : output, error;

import watt.path : temporaryFilename, dirSeparator;
import watt.process : spawnProcess, wait;
import watt.io.file : remove, exists, read;
import watt.io.streams : OutputFileStream;
import watt.conv : toLower;
import watt.text.diff : diff;
import watt.text.sink : StringSink;
import watt.text.format : format;
import watt.text.string : split, endsWith, replace;

import volt.util.path;
import volt.util.perf : Accumulator, Perf, perf;
import volt.exceptions;
import volt.interfaces;
import volt.errors;
import volt.arg;
import volt.token.location;
import ir = volt.ir.ir;

import volt.parser.parser;
import volt.semantic.languagepass;
import volt.llvm.backend;
import volt.util.mangledecoder;

import volt.visitor.visitor;
import volt.visitor.prettyprinter;
import volt.visitor.debugprinter;
import volt.visitor.docprinter;
import volt.visitor.jsonprinter;

import volt.postparse.missing;


/**
 * Default implementation of @link volt.interfaces.Driver Driver@endlink, replace
 * this if you wish to change the basic operation of the compiler.
 */
class VoltDriver : Driver
{
public:
	VersionSet ver;
	TargetInfo target;
	Frontend frontend;
	LanguagePass languagePass;
	Backend backend;

	Pass[] debugVisitors;

protected:
	Arch mArch;
	Platform mPlatform;

	bool mNoLink;
	bool mNoBackend;
	bool mRemoveConditionalsOnly;
	bool mMissingDeps;
	bool mEmitBitcode;

	bool mLinkWithLD;   // Posix/GNU
	bool mLinkWithCC;   // Posix/GNU
	bool mLinkWithLink; // MSVC Link
	string mLinker;

	string mOutput;

	string mDepFile;
	string[] mDepFiles; ///< All files used as input to this compiled.

	string[] mIncludes;
	string[] mSrcIncludes;
	string[] mSourceFiles;
	string[] mImportAsSrc;
	string[] mBitcodeFiles;
	string[] mObjectFiles;
	string[] mLibFiles;

	string[] mLibraryFiles;
	string[] mLibraryPaths;

	string[] mFrameworkNames;
	string[] mFrameworkPaths;

	string[] mStringImportPaths;

	string[] mXld;
	string[] mXcc;
	string[] mXlink;
	string[] mXlinker;

	bool mInternalD;
	bool mInternalDiff;
	bool mInternalDebug;
	bool mInternalNoCatch;

	ir.Module[] mCommandLineModules;

	/// Temporary files created during compile.
	string[] mTemporaryFiles;

	/// Used to track if we should debug print on error.
	bool mDebugPassesRun;

	Accumulator mAccumReading;
	Accumulator mAccumParsing;

	// For the modules generated by CTFE.
	BackendResult[ir.NodeID] mCompiledModules;

	/// If not null, use this to print json files.
	JsonPrinter mJsonPrinter;

	/// Decide on the different parts of the driver to use.
	bool mRunVoltend;
	bool mRunBackend;


public:
	this(Settings s, VersionSet ver, TargetInfo target, string[] files)
	in {
		assert(s !is null);
		assert(ver !is null);
		assert(target !is null);
	}
	body {
		this.ver = ver;
		this.target = target;
		this.execDir = s.execDir;
		this.identStr = s.identStr;
		this.internalDebug = s.internalDebug;

		// Timers
		mAccumReading = new Accumulator("p1-reading");
		mAccumParsing = new Accumulator("p1-parsing");

		setTargetInfo(target, s.arch, s.platform);
		setVersionSet(ver, s.arch, s.platform);

		decideStuff(s);
		decideJson(s);
		decideLinker(s);
		decideOutputFile(s);
		decideCheckErrors();

		addFiles(files);
		auto mode = decideMode(s);
		this.frontend = new Parser(s);
		this.languagePass = new VoltLanguagePass(this, ver, target,
			frontend, mode, s.internalD, s.warningsEnabled);

		decideParts();
		decideBackend();

		debugVisitors ~= new DebugMarker("Running DebugPrinter:");
		debugVisitors ~= new DebugPrinter();
		debugVisitors ~= new DebugMarker("Running PrettyPrinter:");
		debugVisitors ~= new PrettyPrinter();
	}


	/*
	 *
	 * Driver functions.
	 *
	 */

	/**
	 * Retrieve a Module by its name. Returns null if none is found.
	 */
	override ir.Module loadModule(ir.QualifiedName name)
	{
		auto srcPath = pathFromQualifiedName(name, mSrcIncludes, ".volt");
		auto incPath = pathFromQualifiedName(name, mIncludes, ".volt");
		if (srcPath is null && incPath is null) {
			if (!mInternalD) {
				return null;
			}

			srcPath = pathFromQualifiedName(name, mSrcIncludes, ".d");
			incPath = pathFromQualifiedName(name, mIncludes, ".d");
		}

		if (srcPath !is null) {
			mSourceFiles ~= srcPath;
			auto m = loadAndParse(srcPath);
			languagePass.addModule(m);
			mCommandLineModules ~= m;
			return m;
		}
		if (incPath is null) {
			return null;
		}
		return loadAndParse(incPath);
	}

	override string stringImport(Location loc, string fname)
	{
		if (mStringImportPaths.length == 0) {
			throw makeNoStringImportPaths(loc);
		}

		foreach (path; mStringImportPaths) {
			string str;
			try {
				return cast(string)read(format("%s/%s", path, fname));
			} catch (Throwable) {
			}
		}

		throw makeImportFileOpenFailure(loc, fname);
	}

	override ir.Module[] getCommandLineModules()
	{
		return mCommandLineModules;
	}

	override void close()
	{
		foreach (m; mCompiledModules.values) {
			m.close();
		}

		frontend.close();
		languagePass.close();
		if (backend !is null) {
			backend.close();
		}

		frontend = null;
		languagePass = null;
		backend = null;
	}


	/*
	 *
	 * Misc functions.
	 *
	 */

	void addFile(string file)
	{
		version (Windows) {
			// VOLT TEST.VOLT  REM Reppin' MS-DOS
			file = toLower(file);
		}

		if (endsWith(file, ".d", ".volt") > 0) {
			mSourceFiles ~= file;
		} else if (endsWith(file, ".bc")) {
			mBitcodeFiles ~= file;
		} else if (endsWith(file, ".o", ".obj")) {
			mObjectFiles ~= file;
		} else if (endsWith(file, ".lib")) {
			mLibFiles ~= file;
		} else {
			auto str = format("unknown file type '%s'", file);
			throw new CompilerError(str);
		}
	}

	void addFiles(string[] files)
	{
		foreach (file; files) {
			addFile(file);
		}
	}

	int compile()
	{
		int ret = 2;
		mDebugPassesRun = false;
		scope (success) {
			debugPasses();

			foreach (f; mTemporaryFiles) {
				if (f.exists()) {
					f.remove();
				}
			}

			if (ret == 0) {
				writeDepFile();
			}

			perf.mark(Perf.Mark.EXIT);
		}

		if (mInternalNoCatch) {
			ret = intCompile();
			return ret;
		}

		try {
			ret = intCompile();
			return ret;
		} catch (CompilerPanic e) {
			io.error.writefln(e.msg);
			auto loc = e.allocationLocation;
			if (loc != "") {
				io.error.writefln("%s", loc);
			}
			return 2;
		} catch (CompilerError e) {
			io.error.writefln(e.msg);
			auto loc = e.allocationLocation;
			debug if (loc != "") {
				io.error.writefln("%s", loc);
			}
			return 1;
		} catch (Throwable t) {
			io.error.writefln("panic: %s", t.msg);
			version (Volt) auto loc = t.loc;
			else auto loc = t.file is null ? "" : format("%s:%s", t.file, t.line);
			if (loc != "") {
				io.error.writefln("%s", loc);
			}
			return 2;
		}
	}

	override BackendResult hostCompile(ir.Module mod)
	{
		// We cache the result of the module compile here.
		auto p = mod.uniqueId in mCompiledModules;
		if (p !is null) {
			return *p;
		}

		// Need to run phase3 on it first.
		languagePass.phase3([mod]);

		// Then jit compile it so we can run it in our process.
		backend.setTarget(TargetType.Host);
		auto compMod = backend.compile(mod);
		mCompiledModules[mod.uniqueId] = compMod;
		return compMod;
	}


protected:
	void writeDepFile()
	{
		if (mDepFile is null ||
		    mDepFiles is null) {
			return;
		}

		assert(mOutput !is null);

		// We have to be careful that this is a UNIX file.
		auto d = new OutputFileStream(mDepFile);
		d.writef("%s: \\\n", replace(mOutput, `\`, `/`));
		foreach (dep; mDepFiles[0 .. $-1]) {
			d.writef("\t%s \\\n", replace(dep, `\`, `/`));
		}
		d.writefln("\t%s\n", replace(mDepFiles[$-1], `\`, `/`));
		d.flush();
		d.close();
	}

	string pathFromQualifiedName(ir.QualifiedName name, string[] includes,
	                             string suffix)
	{
		string[] validPaths;
		foreach (path; includes) {
			auto paths = genPossibleFilenames(
				path, name.strings, suffix);

			foreach (possiblePath; paths) {
				if (exists(possiblePath)) {
					validPaths ~= possiblePath;
				}
			}
		}

		if (validPaths is null) {
			return null;
		}
		if (validPaths.length > 1) {
			throw makeMultipleValidModules(name, validPaths);
		}
		return validPaths[0];
	}

	/**
	 * Loads a file and parses it.
	 */
	ir.Module loadAndParse(string file)
	{
		// Add file to dependencies for this compile.
		mDepFiles ~= file;

		string src;
		{
			mAccumReading.start();
			scope (exit) mAccumReading.stop();
			src = cast(string) read(file);
		}

		mAccumParsing.start();
		scope (exit) mAccumParsing.stop();
		return frontend.parseNewFile(src, file);
	}

	int intCompile()
	{
		if (mRunVoltend) {
			int ret = intCompileVoltend();
			if (ret != 0) {
				return ret;
			}
		}
		if (mRunBackend) {
			return intCompileBackend();
		}
		return 0;
	}

	int intCompileVoltend()
	{
		// Start parsing.
		perf.mark(Perf.Mark.PARSING);

		// Load all modules to be compiled.
		// Don't run phase 1 on them yet.
		foreach (file; mSourceFiles) {
			debugPrint("Parsing %s.", file);

			auto m = loadAndParse(file);
			languagePass.addModule(m);
			mCommandLineModules ~= m;
		}

		foreach (imp; mImportAsSrc) {
			auto q = new ir.QualifiedName();
			foreach (id; split(imp, '.')) {
				q.identifiers ~= new ir.Identifier(id);
			}
			auto m = loadModule(q);
			bool hasAdded;
			foreach_reverse (other; mCommandLineModules) {
				if (other is m) {
					hasAdded = true;
					break;
				}
			}
			if (!hasAdded) {
				languagePass.addModule(m);
				mCommandLineModules ~= m;
			}
		}

		// Skip setting up the pointers incase object
		// was not loaded, after that we are done.
		if (mRemoveConditionalsOnly) {
			languagePass.phase1(mCommandLineModules);
			return 0;
		}



		// Setup diff buffers.
		auto ppstrs = new string[](mCommandLineModules.length);
		auto dpstrs = new string[](mCommandLineModules.length);

		preDiff(mCommandLineModules, "Phase 1", ppstrs, dpstrs);
		perf.mark(Perf.Mark.PHASE1);

		// Force phase 1 to be executed on the modules.
		// This might load new modules.
		auto lp = cast(VoltLanguagePass)languagePass;
		lp.phase1(mCommandLineModules);
		bool hasPhase1 = true;
		while (hasPhase1) {
			hasPhase1 = false;
			auto mods = lp.getModules();
			foreach (m; mods) {
				hasPhase1 = !m.hasPhase1 || hasPhase1;
				lp.phase1(m);
			}
		}
		postDiff(mCommandLineModules, ppstrs, dpstrs);


		// Are we only looking for missing deps?
		if (mMissingDeps) {
			foreach (m; lp.missing.getMissing()) {
				io.output.writefln("%s", m);
			}
			io.output.flush();
			return 0;
		}


		// After we have loaded all of the modules
		// setup the pointers, this allows for suppling
		// a user defined object module.
		lp.setupOneTruePointers();


		// New modules have been loaded,
		// make sure to run everthing on them.
		auto allMods = languagePass.getModules();


		// All modules need to be run through phase2.
		preDiff(mCommandLineModules, "Phase 2", ppstrs, dpstrs);
		perf.mark(Perf.Mark.PHASE2);
		languagePass.phase2(allMods);
		postDiff(mCommandLineModules, ppstrs, dpstrs);


		// Printout json file.
		if (mJsonPrinter !is null) {
			mJsonPrinter.transform(mCommandLineModules);
		}


		// All modules need to be run through phase3.
		preDiff(mCommandLineModules, "Phase 3", ppstrs, dpstrs);
		perf.mark(Perf.Mark.PHASE3);
		languagePass.phase3(allMods);
		postDiff(mCommandLineModules, ppstrs, dpstrs);


		// For the debug printing here if no exception has been thrown.
		debugPasses();
		return 0;
	}

	int intCompileBackend()
	{
		perf.mark(Perf.Mark.BACKEND);

		// We do this here if we know that object files are
		// being used. Add files to dependencies for this compile.
		foreach (file; mBitcodeFiles) {
			mDepFiles ~= file;
		}

		// We will be modifing this later on,
		// but we don't want to change mBitcodeFiles.
		string[] bitcodeFiles = mBitcodeFiles;
		string subdir = getTemporarySubdirectoryName();

		// Generate bc files for the compiled modules.
		foreach (m; mCommandLineModules) {
			string o = temporaryFilename(".bc", subdir);
			backend.setTarget(TargetType.LlvmBitcode);
			debugPrint("Backend %s.", m.name.toString());
			auto res = backend.compile(m);
			res.saveToFile(o);
			res.close();
			bitcodeFiles ~= o;
			mTemporaryFiles ~= o;
		}

		// Setup files bc.
		string bc;
		if (mEmitBitcode) {
			bc = mOutput;
		} else {
			if (bitcodeFiles.length == 1) {
				bc = bitcodeFiles[0];
				bitcodeFiles = null;
			} else if (bitcodeFiles.length > 1) {
				bc = temporaryFilename(".bc", subdir);
				mTemporaryFiles ~= bc;
			}
		}

		// Link bitcode files.
		if (bitcodeFiles.length > 0) {
			perf.mark(Perf.Mark.BITCODE);
			linkModules(bc, bitcodeFiles);
		}

		// When outputting bitcode we are now done.
		if (mEmitBitcode) {
			return 0;
		}

		// We do this here if we know that object files are
		// being used. Add files to dependencies for this compile.
		foreach (file; mObjectFiles) {
			mDepFiles ~= file;
		}

		// Setup object files and output for linking
		string obj;
		if (mNoLink) {
			assert(bc !is null);
			obj = mOutput;
		} else if (bc !is null) {
			obj = temporaryFilename(".o", subdir);
			mTemporaryFiles ~= obj;
		}

		if (obj !is null) {
			assert(bc !is null);

			// Native compilation, turn the bitcode into native code.
			perf.mark(Perf.Mark.ASSEMBLE);
			writeObjectFile(target, obj, bc);
		}

		// When not linking we are now done.
		if (mNoLink) {
			return 0;
		}

		// And finally call the linker.
		perf.mark(Perf.Mark.LINK);
		return nativeLink(obj, mOutput);
	}

	int nativeLink(string obj, string of)
	{
		auto objs = mObjectFiles;
		if (obj !is null) {
			objs ~= obj;
		}

		if (mLinkWithLink) {
			return msvcLink(mLinker, objs, of);
		} else if (mLinkWithLD) {
			return ccLink(mLinker, false, objs, of);
		} else if (mLinkWithCC) {
			return ccLink(mLinker, true, objs, of);
		} else {
			assert(false);
		}
	}

	int ccLink(string linker, bool cc, string[] objs, string of)
	{
		string[] args = ["-o", of];

		if (cc) {
			final switch (target.arch) with (Arch) {
			case X86: args ~= "-m32"; break;
			case X86_64: args ~= "-m64"; break;
			}
		}

		foreach (objectFile; objs) {
			args ~= objectFile;
		}
		foreach (libraryPath; mLibraryPaths) {
			args ~= format("-L%s", libraryPath);
		}
		foreach (libraryFile; mLibraryFiles) {
			args ~= format("-l%s", libraryFile);
		}
		foreach (frameworkPath; mFrameworkPaths) {
			args ~= "-F";
			args ~= frameworkPath;
		}
		foreach (frameworkName; mFrameworkNames) {
			args ~= "-framework";
			args ~= frameworkName;
		}
		if (cc) {
			foreach (xcc; mXcc) {
				args ~= xcc;
			}
			foreach (xLD; mXld) {
				args ~= "-Xlinker";
				args ~= xLD;
			}
			foreach (xLinker; mXlinker) {
				args ~= "-Xlinker";
				args ~= xLinker;
			}
		} else {
			foreach (xLD; mXld) {
				args ~= xLD;
			}
			foreach (xLink; mXlinker) {
				args ~= xLink;
			}
		}

		return spawnProcess(linker, args).wait();
	}

	int msvcLink(string linker, string[] objs, string of)
	{
		string[] args = [
			"/MACHINE:x64",
			"/defaultlib:libcmt",
			"/defaultlib:oldnames",
			"legacy_stdio_definitions.lib",
			"/nologo",
			format("/out:%s", of)];

		foreach (objectFile; objs) {
			args ~= objectFile;
		}
		foreach (libFile; mLibFiles) {
			args ~= libFile;
			mDepFiles ~= libFile;
		}
		foreach (libraryPath; mLibraryPaths) {
			args ~= format("/LIBPATH:%s", libraryPath);
		}
		foreach (libraryFile; mLibraryFiles) {
			args ~= libraryFile;
		}
		foreach (xLink; mXlink) {
			args ~= xLink;
		}

		// We are using msvc link directly so this is
		// linker arguments.
		foreach (xLinker; mXlinker) {
			args ~= xLinker;
		}

		return spawnProcess(linker, args).wait();
	}

	int emscriptenLink(string linker, string bc, string of)
	{
		string[] args = ["-o", of];
		return spawnProcess(linker, ["-o", of, bc]).wait();
	}


	/*
	 *
	 * Decision methods.
	 *
	 */

	static Mode decideMode(Settings settings)
	{
		if (settings.removeConditionalsOnly) {
			return Mode.RemoveConditionalsOnly;
		} else if (settings.missingDeps) {
			return Mode.MissingDeps;
		} else {
			return Mode.Normal;
		}
	}

	void decideStuff(Settings settings)
	{
		mArch = settings.arch;
		mPlatform = settings.platform;

		mNoLink = settings.noLink;
		mNoBackend = settings.noBackend;
		mMissingDeps = settings.missingDeps;
		mEmitBitcode = settings.emitBitcode;
		mRemoveConditionalsOnly = settings.removeConditionalsOnly;

		mInternalD = settings.internalD;
		mInternalDiff = settings.internalDiff;
		mInternalDebug = settings.internalDebug;
		mInternalNoCatch = settings.noCatch;

		mDepFile = settings.depFile;

		mIncludes = settings.includePaths;
		mSrcIncludes = settings.srcIncludePaths;
		mImportAsSrc = settings.importAsSrc;

		mLibraryPaths = settings.libraryPaths;
		mLibraryFiles = settings.libraryFiles;

		mFrameworkNames = settings.frameworkNames;
		mFrameworkPaths = settings.frameworkPaths;

		mStringImportPaths = settings.stringImportPaths;
	}

	void decideJson(Settings settings)
	{
		if (settings.jsonOutput !is null) {
			mJsonPrinter = new JsonPrinter(settings.jsonOutput);
		}
	}

	void decideLinker(Settings settings)
	{
		mXld = settings.xld;
		mXcc = settings.xcc;
		mXlink = settings.xlink;
		mXlinker = settings.xlinker;

		if (settings.linker !is null) {
			switch (mPlatform) with (Platform) {
			case MSVC:
				mLinker = settings.linker;
				mLinkWithLink = true;
				break;
			default:
				mLinker = settings.linker;
				mLinkWithLD = true;
				break;
			}
		} else if (settings.ld !is null) {
			mLinker = settings.ld;
			mLinkWithLD = true;
		} else if (settings.cc !is null) {
			mLinker = settings.cc;
			mLinkWithCC = true;
		} else if (settings.link !is null) {
			mLinker = settings.link;
			mLinkWithLink = true;
		} else {
			switch (mPlatform) with (Platform) {
			case MSVC:
				mLinker = "link.exe";
				mLinkWithLink = true;
				break;
			default:
				mLinkWithCC = true;
				mLinker = "gcc";
				break;
			}
		}
	}

	void decideOutputFile(Settings settings)
	{
		// Setup the output file
		if (settings.outputFile !is null) {
			mOutput = settings.outputFile;
			if (mLinkWithLink && !mNoLink && !mEmitBitcode
				&& !mOutput.endsWith("exe")) {
				mOutput = format("%s.exe", mOutput);
			}
		} else if (mEmitBitcode) {
			mOutput = DEFAULT_BC;
		} else if (mNoLink) {
			mOutput = DEFAULT_OBJ;
		} else {
			mOutput = DEFAULT_EXE;
		}
	}

	void decideCheckErrors()
	{
		if (mLibFiles.length > 0 && !mLinkWithLink) {
			throw new CompilerError(format("can not link '%s'", mLibFiles[0]));
		}
	}

	void decideParts()
	{
		mRunVoltend = mSourceFiles.length > 0;

		mRunBackend =
			!mNoBackend &&
			!mMissingDeps &&
			!mRemoveConditionalsOnly;
	}

	void decideBackend()
	{
		if (mRunBackend) {
			assert(languagePass !is null);
			backend = new LlvmBackend(languagePass);
		}
	}


private:
	/**
	 * If we are debugging print messages.
	 */
	void debugPrint(string msg, string s)
	{
		if (mInternalDebug) {
			io.output.writefln(msg, s);
		}
	}

	void debugPasses()
	{
		if (mInternalDebug && !mDebugPassesRun) {
			mDebugPassesRun = true;
			foreach (pass; debugVisitors) {
				foreach (mod; mCommandLineModules) {
					pass.transform(mod);
				}
			}
		}
	}

	void preDiff(ir.Module[] mods, string title, string[] ppstrs, string[] dpstrs)
	{
		if (!mInternalDiff) {
			return;
		}

		assert(mods.length == ppstrs.length && mods.length == dpstrs.length);
		StringSink ppBuf, dpBuf;
		version (Volt) {
			auto diffPP = new PrettyPrinter(" ", ppBuf.sink);
			auto diffDP = new DebugPrinter(" ", dpBuf.sink);
		} else {
			auto diffPP = new PrettyPrinter(" ", ppBuf.sink);
			auto diffDP = new DebugPrinter(" ", dpBuf.sink);
		}
		foreach (i, m; mods) {
			ppBuf.reset();
			dpBuf.reset();
			io.output.writefln("Transformations performed by %s:", title);
			diffPP.transform(m);
			diffDP.transform(m);
			ppstrs[i] = ppBuf.toString();
			dpstrs[i] = dpBuf.toString();
		}
		diffPP.close();
		diffDP.close();
	}

	void postDiff(ir.Module[] mods, string[] ppstrs, string[] dpstrs)
	{
		if (!mInternalDiff) {
			return;
		}
		assert(mods.length == ppstrs.length && mods.length == dpstrs.length);
		StringSink sb;
		version (Volt) {
			auto pp = new PrettyPrinter(" ", sb.sink);
			auto dp = new DebugPrinter(" ", sb.sink);
		} else {
			auto pp = new PrettyPrinter(" ", &sb.sink);
			auto dp = new DebugPrinter(" ", &sb.sink);
		}
		foreach (i, m; mods) {
			sb.reset();
			dp.transform(m);
			diff(dpstrs[i], sb.toString());
			sb.reset();
			pp.transform(m);
			diff(ppstrs[i], sb.toString());
		}
		pp.close();
		dp.close();
	}
}

TargetInfo setTargetInfo(TargetInfo target, Arch arch, Platform platform)
{
	target.arch = arch;
	target.platform = platform;

	final switch (arch) with (Arch) {
	case X86:
		target.isP64 = false;
		target.ptrSize = 4;
		target.alignment.int1 = 1;
		target.alignment.int8 = 1;
		target.alignment.int16 = 2;
		target.alignment.int32 = 4;
		target.alignment.int64 = 4; // abi 4, prefered 8
		target.alignment.float32 = 4;
		target.alignment.float64 = 4; // abi 4, prefered 8
		target.alignment.ptr = 4;
		target.alignment.aggregate = 8; // abi X, prefered 8
		break;
	case X86_64:
		target.isP64 = true;
		target.ptrSize = 8;
		target.alignment.int1 = 1;
		target.alignment.int8 = 1;
		target.alignment.int16 = 2;
		target.alignment.int32 = 4;
		target.alignment.int64 = 8;
		target.alignment.float32 = 4;
		target.alignment.float64 = 8;
		target.alignment.ptr = 8;
		target.alignment.aggregate = 8; // abi X, prefered 8
		break;
	}

	return target;
}

void setVersionSet(VersionSet ver, Arch arch, Platform platform)
{
	final switch (platform) with (Platform) {
	case MinGW:
		ver.overwriteVersionIdentifier("Windows");
		ver.overwriteVersionIdentifier("MinGW");
		break;
	case MSVC:
		ver.overwriteVersionIdentifier("Windows");
		ver.overwriteVersionIdentifier("MSVC");
		break;
	case Linux:
		ver.overwriteVersionIdentifier("Linux");
		ver.overwriteVersionIdentifier("Posix");
		break;
	case OSX:
		ver.overwriteVersionIdentifier("OSX");
		ver.overwriteVersionIdentifier("Posix");
		break;
	case Metal:
		ver.overwriteVersionIdentifier("Metal");
		break;
	}
	final switch (arch) with (Arch) {
	case X86:
		ver.overwriteVersionIdentifier("X86");
		ver.overwriteVersionIdentifier("LittleEndian");
		ver.overwriteVersionIdentifier("V_P32");
		break;
	case X86_64:
		ver.overwriteVersionIdentifier("X86_64");
		ver.overwriteVersionIdentifier("LittleEndian");
		ver.overwriteVersionIdentifier("V_P64");
		break;
	}
}

version (Windows) {
	enum DEFAULT_BC = "a.bc";
	enum DEFAULT_OBJ = "a.obj";
	enum DEFAULT_EXE = "a.exe";
} else {
	enum DEFAULT_BC = "a.bc";
	enum DEFAULT_OBJ = "a.obj";
	enum DEFAULT_EXE = "a.out";
}
