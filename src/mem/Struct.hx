package mem;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.ExprTools;
import haxe.macro.TypeTools;
import mem._macros.IDXParams;
import StringTools.hex;
import StringTools.rpad;
import haxe.macro.PositionTools.here;
#end

/**
Supported field types:

```
mem.Ptr          @idx(sizeof = 4, offset = 0):
  - or "abstract XXX(Ptr){}"

Bool:            @idx(sizeof = 1, offset = 0)
String           @idx(bytes  = 1, offset = 0)
Int: (1), 2, 4   @idx(sizeof = 1, offset = 0)
Float: (4), 8    @idx(sizeof = 4, offset = 0)
AU8              @idx(count  = 1, offset = 0) [bytesLength = count * sizeof(1)]
AU16             @idx(count  = 1, offset = 0) [bytesLength = count * sizeof(2)]
AI32             @idx(count  = 1, offset = 0) [bytesLength = count * sizeof(4)]
AF4              @idx(count  = 1, offset = 0) [bytesLength = count * sizeof(4)]
AF8              @idx(count  = 1, offset = 0) [bytesLength = count * sizeof(8)]
```
*/
class Struct {
#if macro
	static inline var IDX = "idx";

	static var def = new haxe.ds.StringMap<IDXParams>();

	static function expr_cast(e: Expr, unsafe: Bool): Expr {
		return unsafe ? { expr: ECast(e, null), pos: e.pos } : e;
	}

	static function is_tptr(t: Type): Bool {
		return
		if (TypeTools.toString(t) == "mem.Ptr")
			true;
		else
			switch(t) {
			case TAbstract(a, _): is_tptr(a.get().type);
			default: false;
			}
	}

	static function to_full(pack, name) {
		return pack.length == 0 ? name : pack.join(".") + "." + name;
	}

	static public function auto(?fixedmem: {bulk: Int, ?extra: Int}) {
		var alloc_s = "Mem";
		var cls:ClassType = Context.getLocalClass().get();
		var abst = switch (cls.kind) {
			case KAbstractImpl(_.get() => t):
				if (fixedmem != null) {
					alloc_s = to_full(t.pack, t.name);
					if (cls.isExtern) Context.error("No \"extern\" if fixedmem", cls.pos);
				}
				t;
			default:
				Context.error("UnSupported Type", cls.pos);
		}
		var alloc = macro $i{ alloc_s };
		var ct_ptr = macro :mem.Ptr;
		var ct_int = macro :Int;
		var ct_bool= macro :Bool;

		var fields:Array<Field> = Context.getBuildFields();
		var offset_first = 0;
		var offset = 0;
		var flexible = false;
		var idx = new IDXParams();
		var all_fields = new haxe.ds.StringMap<Bool>();

		var fds = fields.filter(function(f) {
			all_fields.set(f.name, true);
			switch (f.kind) {
			case FVar(_, _) if (f.meta != null):
				for (meta in f.meta) {
					if (meta.name == IDX) {
						if (f.access.indexOf(AStatic) > -1) Context.error("doesn't support static properties", f.pos);
						return true;
					}
				}
			default:
			}
			return false;
		});

		for (f in fds) {
			idx.reset();
			for (meta in f.meta) {
				if (meta.name == IDX) {
					idx.parse(meta);
					break; // only first @idx
				}
			}
			var unsafe_cast = false;
			switch (f.kind) {
			case FVar(vt = TPath(path), _):
				var t = Context.getType(to_full(path.pack, path.name));
				var ts = "";
				var exprs: Array<Expr> = null;
				var setter_value: Expr = macro v;
				setter_value.pos = f.pos;
				switch (t) {
				case TAbstract(a, _):
					var at = a.get();
					if (at.meta.has(":enum")) { // for enum abstract XXX{}
						switch (Context.followWithAbstracts(t)) {
						case TAbstract(sa , _):
							var sas = sa.toString();
							if (sas == "Int" || sas == "Float") {
								unsafe_cast = true;
								setter_value = expr_cast(setter_value, true);
								a = sa;
							}
						case _:
						}
					}
					ts = a.toString();
					switch (ts) {
					case "Bool":
						idx.sizeOf = 1;
						offset += idx.offset;
						exprs = [macro (this+$v{offset}).getByte() != 0, macro (this+$v{offset}).setByte($setter_value ? 1 : 0)];
					case "Int":
						offset += idx.offset;
						var sget = "getByte", sset = "setByte";
						switch (idx.sizeOf) {
						case 2: sget = "getUI16"; sset = "setI16";
						case 4: sget = "getI32"; sset = "setI32";
						default: idx.sizeOf = 1;
						}
						exprs = [macro (this+$v{offset}).$sget(), macro (this+$v{offset}).$sset($setter_value)];
					case "Float":
						offset += idx.offset;
						var sget = "getFloat", sset = "setFloat";
						if (idx.sizeOf == 8) {
							sget = "getDouble"; sset = "setDouble";
						} else {
							idx.sizeOf = 4;
						}
						exprs = [macro (this+$v{offset}).$sget(), macro (this+$v{offset}).$sset($setter_value)];
					case "mem.Ptr":
						unsafe_cast = true;
						setter_value = expr_cast(setter_value, true);
						idx.sizeOf = 4;
						offset += idx.offset;
						exprs = [macro (this+$v{offset}).getI32(), macro (this+$v{offset}).setI32($setter_value)];
					default:
						if (is_tptr(at.type)) {
							unsafe_cast = true;
							setter_value = expr_cast(setter_value, true);
							if (at.meta.has(IDX)) {              // parse meta from the class define, see: [AU8, AU16, AI32]
								var FORCE = def.get(ts);
								if (FORCE == null) {
									FORCE = new IDXParams();
									FORCE.parse(at.meta.extract(IDX)[0]);
									def.set(ts, FORCE);
								}
								if (FORCE.unSupported()) Context.error("Type (" + ts +") is not supported for field: " + f.name , f.pos);
								if (FORCE.isArray()) {           // force override
									idx.count  = idx.sizeOf;     // first argument is "count";
									idx.sizeOf = FORCE.sizeOf;
									idx.extra  = FORCE.extra;
								}
							}
							if (idx.isArray()) {                 // Struct Block
								if (ts == to_full(abst.pack, abst.name)) Context.error("Nested error", f.pos);
								if (idx.count == 0) {
									if (f == fds[fds.length - 1]) {
										flexible = true;
									} else {
										Context.error("the flexible array member is supports only for the final field.", f.pos);
									}
								}
								offset += idx.offset;
								exprs = [(macro (this + $v{offset})), null];
							} else {                             // Point to Struct
								if (idx.argc == 0) idx.sizeOf = 4;
								if (idx.sizeOf != 4) Context.error("first argument of @idx must be empty or 4.", f.pos);
								offset += idx.offset;
								exprs = [macro (this+$v{offset}).getI32(), macro (this+$v{offset}).setI32($setter_value)];
							}
						}
					}
				case TInst(s, _):
					ts = Std.string(s);
					if (ts == "String") {
						offset += idx.offset;
						idx.count = idx.sizeOf;
						idx.sizeOf = 1;
						exprs = [macro Mem.readUtf8(this + $v{offset}, $v{idx.count}),
							macro Mem.writeUtf8(this + $v{offset}, $v{idx.count}, v)
						];
					}
				default:
					ts = haxe.macro.TypeTools.toString(t); // for error.
				}

				if (exprs == null) {
					Context.error("Type (" + ts +") is not supported for field: " + f.name , f.pos);
				} else {
					if (idx.bytes == 0 && flexible == false) Context.error("Something is wrong", f.pos);
					if (f == fds[0]) {
						if (offset > 0) Context.error("offset of the first field can only be <= 0",f.pos);
						offset_first = offset;
					} else if (offset < offset_first) {
						Context.error("offset is out of range", f.pos);
					}
					var getter = expr_cast(exprs[0], unsafe_cast);
					var setter = exprs[1];
					var getter_name = "get_" + f.name;
					var setter_name = "set_" + f.name;
					f.kind = FProp("get", (setter == null ? "never" : "set"), vt, null);
					if (f.access.length == 0 && f.name.charCodeAt(0) != "_".code)
						f.access = [APublic];
					if (!all_fields.exists(getter_name))
						fields.push({
							name : getter_name,
							access: [AInline, APrivate],
							kind: FFun({
								args: [],
								ret : vt,
								expr: macro {
									return $getter;
								}
							}),
							pos: f.pos
						});
					if (setter!= null && !all_fields.exists(setter_name))
						fields.push({
							name: setter_name,
							access: [AInline, APrivate],
							kind: FFun({
								args: [{name: "v", type: vt}],
								ret : vt,
								expr: macro {
									$setter;
									return v;
								}
							}),
							pos: f.pos
						});
					fields.push({
						name : "OFFSETOF_" + f.name.toUpperCase(),
						access: [AStatic, AInline, APublic],
						doc: "" + $v{offset},
						kind: FVar(macro :Int, macro $v{offset}),
						pos: f.pos
					});
					offset += idx.bytes;
				}
			default:
			}

		}
		if (offset - offset_first <= 0) return null;
		fields.push({
			name : "CAPACITY",    // similar "sizeof struct"
			doc:  "" + $v{offset - offset_first},
			access: [AStatic, AInline, APublic],
			kind: FVar(ct_int, macro $v{offset - offset_first}),
			pos: cls.pos
		});
		fields.push({
			name : "OFFSET_FIRST",// Relative to "this"
			doc:  "" + $v{offset_first},
			access: [AStatic, AInline, APublic],
			kind: FVar(ct_int, macro $v{offset_first}),
			pos: cls.pos
		});
		fields.push({
			name : "OFFSET_END",  // Relative to "this"
			doc:  "" + $v{offset},
			access: [AStatic, AInline, APublic],
			kind: FVar(ct_int, macro $v{offset}),
			pos: cls.pos
		});
		if (fixedmem != null) {
			alloc = macro $alloc.__f;
			if (fixedmem.extra == null) fixedmem.extra = 0;
			if (fixedmem.bulk < 1) fixedmem.bulk = 1;
			var f_sz = Ut.align(fixedmem.extra + offset - offset_first, 8);
			fields.push({
			name : "__f",
			access: [AStatic],
			kind: FVar(macro :mem.Fixed, macro new mem.Fixed($v{f_sz}, $v{fixedmem.bulk})),
			pos: cls.pos
			});
		}
		if (!all_fields.exists("_new"))
			fields.push({
				name : "new",
				access: [AInline, APublic],
				kind: flexible && fixedmem == null ? FFun({
					args: [{name: "extra", type: ct_int}],
					ret : null,
					expr: (macro this = alloc(CAPACITY + extra, true))
				}) : FFun({
					args: [],
					ret : null,
					expr: (macro this = alloc(CAPACITY, true))
				}),
				pos: cls.pos
			});
		if (!all_fields.exists("free"))
			fields.push({
				name : "free",
				access: [AInline, APublic],
				kind: FFun({
					args: [],
					ret : macro: Void,
					expr: (macro $alloc.free(realptr()))
				}),
				pos: cls.pos
			});
		if (!all_fields.exists("realptr")) //
			fields.push({
				name : "realptr",
				access: [AInline, APrivate],
				kind: FFun({
					args: [],
					ret : ct_ptr,
					expr: (macro return this + OFFSET_FIRST)
				}),
				pos: cls.pos
			});
		if (!all_fields.exists("alloc")) { // private
			fields.push({
				name : "alloc",
				access: [AInline, APrivate],
				kind: FFun({
					args: [{name: "size", type: ct_int}, {name: "clean", type: ct_bool}],
					ret : ct_ptr,
					expr: fixedmem == null
						? (macro return $alloc.malloc(size, clean) - OFFSET_FIRST)
						: (macro return $alloc.malloc(clean) - OFFSET_FIRST)
				}),
				pos: cls.pos
			});
		}
		return fields;
	}
#end
}
