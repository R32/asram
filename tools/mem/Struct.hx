package mem;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.ExprTools;
import haxe.macro.TypeTools;
import haxe.macro.PositionTools.here;
import StringTools.hex;

typedef Param = {
	width:Int, // sizeof
	nums:Int,
	dx:Int
};

#else
/**
Supported Types:

```
mem.Ptr                     @idx(?offset)         [bytes = 4, default offset = 0]
  - or "abstruct Other(Ptr){}"
Bool:                       @idx(?offset)         [bytes = 1]
Enum                        @idx(?offset)         [bytes = 1]
String                      @idx(length, ?offset) [bytes = length]
Int: (1), 2, 4              @idx(?bytes, ?offset) [default bytes = 1]
Float: (4), 8               @idx(?bytes, ?offset) [default bytes = 4]
//haxe.EnumFlags: (1), 2, 4 @idx(?bytes, ?offset) [default bytes = 1]              - not recommended
//Array<Int|Float>          @idx(length, ?bytes, ?offset) [space = length * bytes] - not recommended, use AU8,AU16,AI32...
// - Int: (1), 2, 4
// - Float: (4), 8
AU8                         @idx(length, ?offset) [space = length * 1 bytes]
AU16                        @idx(length, ?offset) [space = length * 2 bytes]
AI32                        @idx(length, ?offset) [space = length * 4 bytes]
AF4                         @idx(length, ?offset) [space = length * 4 bytes]
AF8                         @idx(length, ?offset) [space = length * 8 bytes]
Ucs2                        @idx(length, ?offset) [space = length * 2 bytes]
```
*/
@:autoBuild(mem.StructBuild.make())
#end
@:remove interface Struct {
	var addr(default, null): mem.Ptr;

/*  make all @idx fields as inline getter/setter;

	and if not have, macro will be auto create below these:
	public var addr(default, null):mem.Ptr;

	public inline function new(){
		addr = Ram.malloc(CAPACITY, true);
	}

	public inline function free(p:Ptr){
		mem.Malloc.free(ptr);
		this.addr = mem.Malloc.NUL;
	}

	public inline function __toOut():String{
		return "long ....";
	}

	static inline var CAPACITY:Int = typeof(this struct);
	static inline var ALL_FIELDS:iterator = ["field_1_name", "field_2_name" .....];
*/
}

class StructBuild{
#if macro
	static inline var IDX = "idx";

	static function parseInt(s:String):Int {
		var i:Int = Std.parseInt(s);
		if (s == null || i == null || Math.isNaN(i))
			throw "todo";
		return i;
	}

	static inline function notZero(v:Int, def:Int = 1) return v <= 0 ? def : v;

	static function parseMeta(arr:Array<Int>, type:String):Param {
		var ret;
		var len = arr.length;
		switch(type){
			case "Bool", "Enum":
				ret = {width:1, dx: arr[0], nums: 1};
			case "Array":
				ret = {
					width: len > 1 ? notZero(arr[1]) : 1,
					dx: len > 2 ? arr[2] : 0,
					nums: notZero(arr[0])
				};
			case "mem.Ptr":
				ret = { width:4, dx: arr[0], nums: 1 };
			case "mem.AU8":
				ret = { width:1, dx: (len > 1 ? arr[1] : 0), nums: notZero(arr[0]) };
			case "mem.AU16" | "mem.Ucs2":
				ret = { width:2, dx: (len > 1 ? arr[1] : 0), nums: notZero(arr[0]) };
			case "mem.AI32":
				ret = { width:4, dx: (len > 1 ? arr[1] : 0), nums: notZero(arr[0]) };
			case "mem.AF4":
				ret = { width:4, dx: (len > 1 ? arr[1] : 0), nums: notZero(arr[0]) };
			case "mem.AF8":
				ret = { width:8, dx: (len > 1 ? arr[1] : 0), nums: notZero(arr[0]) };
			default: // Float, String, Int, haxe.EnumFlags
				ret = { width: notZero(arr[0]), dx: (len > 1 ? arr[1] : 0), nums: 1 };
		}
		return ret;
	}

	static public function make(context = "addr", ?allocter:{free: String, alloc: String}) {
		var cls:ClassType = Context.getLocalClass().get();
		if (cls.isInterface) return null;
		var fields:Array<Field> = Context.getBuildFields();

		var mem = allocter != null ? {
			free: allocter.free.split("."), // "Ram.free" => ["Ram", "free"] for "macro $p{XXX}"
			alloc: allocter.alloc.split(".")
		} : {
			free: ["Ram","free"],
			alloc: ["Ram","malloc"]
		}

		var abs_type  = null;
		switch (cls.kind) {
			case KAbstractImpl(_.get() => t):
				abs_type = t;
			default:
		}
		if (abs_type != null) context = "this";

		var all_fields:Array<String> = [];
		var attrs = {};
		var offset_first = 0;
		var offset_first_ready = false;
		var offset = 0;
		var params:Param;
		var metaParams;

		var all_in_map = new haxe.ds.StringMap<Field>();

		for (f in fields) all_in_map.set(f.name, f);

		for (f in fields) {
			var is_array = false;
			var unsafe_cast = false;
			metaParams = null;
			params = null;
			if(f.meta != null)
				for(meta in f.meta){
					if (meta.name == IDX){
						metaParams = [];
						for (ex in meta.params) {
							try {
								metaParams.push(parseInt(ExprTools.getValue(ex)));
							}catch(err: Dynamic) {
								Context.error("Invalid Meta value for @" + IDX, f.pos);
							}
						}
						if (metaParams.length == 0) metaParams.push(0);
					}
				}
			if (metaParams == null) continue;

			if (f.access.indexOf(AStatic) > -1) Context.error("Does not support static properties", f.pos);

			switch (f.kind) {
			case FVar(vt = TPath({pack: pack, name: name, params:arrType}), init):
				var path = pack.copy();
				path.push(name);
				var t = Context.getType(path.join("."));
				var ts = "";
				var exprs = switch (t) {
					case TAbstract(a, _):
						if (a.get().meta.has(":enum"))
							switch (Context.followWithAbstracts(t)) {
							case TAbstract(follow_a , _):
								unsafe_cast = true;
								a = follow_a;
							case _:
							}

						ts = Std.string(a);
						params = parseMeta(metaParams, ts);
						var expr_value = unsafe_cast == false ? (macro v) : (macro cast v); // argument name are "v"
						expr_value.pos = f.pos;
						switch (ts) {
						case "Bool":
							offset += params.dx;
							[macro Memory.getByte($i{context} + $v{offset}) != 0, macro Memory.setByte($i{context} + $v{offset}, $expr_value ? 1 : 0)];
						case "Int":
							offset += params.dx;
							var sget = "getByte", sset = "setByte";
							switch (params.width) {
							case 2: sget = "getUI16"; sset = "setI16";
							case 4: sget = "getI32"; sset = "setI32";
							default: params.width = 1;
							}
							[macro Memory.$sget($i{context} + $v{offset}), macro (Memory.$sset($i{context} + $v{offset}, $expr_value))];
						case "Float":
							offset += params.dx;
							var sget = "getFloat", sset = "setFloat";
							if (params.width == 2) params.width = 8;
							if(params.width == 8){
								sget = "getDouble"; sset = "setDouble";
							}else{
								params.width = 4;
							}
							[macro Memory.$sget($i{context} + $v{offset}), macro (Memory.$sset($i{context} + $v{offset}, $expr_value))];
						case "haxe.EnumFlags":
							offset += params.dx;
							switch(arrType[0]){	// ComplexType
							case TPType(ct):
								var paramType = Context.resolveType(ct, f.pos);
								if (Context.unify(paramType, Context.getType("haxe.Constraints.FlatEnum")) == false)
									Context.error("Must be FlatEnum", f.pos);
								var sget = "getByte", sset = "setByte";
								switch(params.width){
								case 2: sget = "getUI16"; sset = "setI16";
								case 4: sget = "getI32"; sset = "setI32";
								default: params.width = 1;
								}
								if (params.width * 8 < TypeTools.getEnum(paramType).names.length)
									throw "Unsupported width for EnumFlags" + params.width;
								[macro { new haxe.EnumFlags<$ct>(Memory.$sget($i{context} + $v{offset}));}
									, macro { Memory.$sset($i{context} + $v{offset}, v.toInt());}];
							default: throw "EnumFlags instance expected";
							}
						case "mem.AU8" | "mem.AU16" | "mem.AI32" | "mem.AF4" | "mem.AF8" | "mem.Ucs2":
							is_array = true;
							unsafe_cast = true;
							offset += params.dx;
							[(macro ($i{ context } + $v{ offset })), null]; // null is never
						case "mem.Ptr":
							unsafe_cast = true;
							offset += params.dx;
							[macro (Memory.getI32($i{context} + $v{offset})), macro (Memory.setI32($i{context} + $v{offset}, $expr_value))];
						default:
							ts = TypeTools.toString(a.get().type);
							if (abs_type != null && ts == "mem.Ptr") {  // for abstruct Other(Ptr) {}
								unsafe_cast = true;
								params = parseMeta(metaParams, ts);
								offset += params.dx;
								[macro (Memory.getI32($i{context} + $v{offset})), macro (Memory.setI32($i{context} + $v{offset}, $expr_value))];
							} else {
								null;
							}
						}
					case TEnum(e, _):
						if (Context.unify(t, Context.getType("haxe.Constraints.FlatEnum")) == false)
							Context.error("Must be FlatEnum", f.pos);
						ts = Std.string(e);
						params = parseMeta(metaParams, ts);
						offset += params.dx;
						params.width = 1;
						var epr = Context.getTypedExpr({expr:TTypeExpr(TEnumDecl(e)), t:t, pos:f.pos});
						[macro haxe.EnumTools.createByIndex($epr, Memory.getByte($i{context} + $v{offset})),
							macro Memory.setByte($i{context} + $v{offset}, Type.enumIndex(v))];

					case TInst(s, _):
						ts = Std.string(s);
						params = parseMeta(metaParams, ts);
						offset += params.dx;
							switch(ts) {
							case "String":
							[macro Ram.readUTFBytes($i{context} + $v{offset}, $v{params.width})
								,macro Ram.writeString($i{context} + $v{offset}, $v{params.width} ,v)];
							case "Array":
								is_array = true;
								switch (arrType[0]) {
								case TPType(ct = TPath(at)):
									var sget = null, sset = null;
									switch (at.name) {
										case "Int":
											switch(params.width){
											case 2: sget = "getUI16"; sset = "setI16";
											case 4: sget = "getI32"; sset = "setI32";
											default:
												params.width = 1;
												sget = "getByte"; sset = "setByte";
											}
										case "Float":
											if (params.width == 2) params.width = 8;
											if(params.width == 8){
												sget = "getDouble"; sset = "setDouble";
											}else{
												params.width = 4;
												sget = "getFloat"; sset = "setFloat";
											}
										default: null;
									}// end(at.name)
									if (sget == null || sset == null) {
										null;
									} else {
										[macro{[for (i in 0...$v{params.nums}) Memory.$sget($i{context} + $v{offset} + i)];
										}, macro{ for (i in 0...$v{params.nums}) Memory.$sset($i{context} + $v{offset} + i, v[i]); }];
									}
								default: null;
								}
							default: null;
							}
					default: null;
				}

				if (exprs == null) {
					Context.error("Type (" + ts +") is not supported for field: " + f.name , f.pos);
				} else {
					var getter = unsafe_cast == false ? exprs[0] : {expr: ECast(exprs[0], null), pos: f.pos};
					var setter = exprs[1];
					var getter_name = "get_" + f.name;
					var setter_name = "set_" + f.name;
					f.kind = FProp("get", (setter == null ? "never" : "set"), vt, null);
					if (f.access.length == 0) f.access = [APublic];

					if (!all_in_map.exists(getter_name))
					fields.push({
						name : getter_name,
						access: [AInline],
						kind: FFun({
							args: [],
							ret : vt,
							expr: macro {
								return $getter;
							}
						}),
						pos: f.pos
					});

					if (setter!= null && !all_in_map.exists(setter_name))
					fields.push({
						name: setter_name,
						access: [AInline],
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
						name : "__" + f.name.toUpperCase() + "_OF",
						access: [AStatic, AInline, APublic],
						doc: " == " + $v{offset},
						kind: FVar(macro :Int, macro $v{offset}),
						pos: f.pos
					});

					fields.push({
						name : "__" + f.name.toUpperCase() + "_LEN",
						doc: " == " + $v{is_array ? params.nums : params.width},
						access: [AStatic, AInline, APublic],
						kind: FVar(macro :Int, macro $v{is_array ? params.nums : params.width}),
						pos: f.pos
					});

					if (offset_first_ready == false) {
						if (offset < 0) offset_first = offset;
						offset_first_ready = true;
					}
					if (offset < offset_first) Context.error("Out of range", f.pos);

					if(is_array){
						fields.push({
							name : "__" + f.name.toUpperCase() + "_BYTE",
							access: [AStatic, AInline, APublic],
							doc: " == " + $v{params.width * params.nums},
							kind: FVar(macro :Int, macro $v{params.width * params.nums}),
							pos: f.pos
						});

						Reflect.setField(attrs, f.name, {offset: offset, bytes: params.width, len: params.nums});
						offset += params.nums * params.width;
					}else{
						Reflect.setField(attrs, f.name, {offset: offset, len: params.width, bytes: 1});
						offset += params.width;
					}
					all_fields.push(f.name);
				}

			default:
			}

		}
	if (offset - offset_first > 0) {

		fields.push({
			name : "CAPACITY",    // Some similar "sizeof struct"
			doc:  "== " + $v{offset - offset_first},
			access: [AStatic, AInline, APublic],
			kind: FVar(macro :Int, macro $v{offset - offset_first}),
			pos: cls.pos
		});

		fields.push({
			name : "OFFSET_FIRST",// This field may be "Negative"
			doc:  "== " + $v{offset_first},
			access: [AStatic, AInline, APublic],
			kind: FVar(macro :Int, macro $v{offset_first}),
			pos: cls.pos
		});

		fields.push({
			name : "OFFSET_END",  // If you want to add a flexible field at the end of the struct
			doc:  "== " + $v{offset},
			access: [AStatic, AInline, APublic],
			kind: FVar(macro :Int, macro $v{offset}),
			pos: cls.pos
		});

		fields.push({
			name : "ALL_FIELDS",
			meta: [{name: ":dce", pos: cls.pos}],
			doc:  "== " + $v{all_fields.length},
			access: [AStatic, AInline, APublic],
			kind: FFun({
					args: [],
					ret : macro :Iterator<String>,
					expr: macro {
						return $v{all_fields}.iterator();
					}
				}),
			pos: cls.pos
		});

		var constructor = all_in_map.get(abs_type == null ? "new" : "_new");
		if (constructor == null) {
			fields.push({
				name : "new",
				access: [AInline, APublic],
				kind: FFun({
					args: [],
					ret : null,
					expr: macro {
						mallocAbind(CAPACITY, true);
					}
				}),
				pos: here()
			});
		}else if (abs_type != null && constructor.access.indexOf(AInline) == -1){
			Context.warning("Suggestion: add **inline** for " + cls.name, constructor.pos);
		}

		if (!all_in_map.exists("mallocAbind")) // malloc and bind Context
			fields.push({
				name : "mallocAbind",
				meta: [{name: ":dce", pos: cls.pos}],
				doc: ' help for custom constructor',
				access: [AInline, APrivate],
				kind: FFun({
				args: [{name: "entry_size", type: macro :Int}, {name: "zero", type: macro :Bool}],
					ret : macro :Void,
					expr: macro {
						$i{context} = $p{mem.alloc}(entry_size, zero) - OFFSET_FIRST; // offset_first <= 0
					}
				}),
				pos: here()
			});

		if (!all_in_map.exists("realEntry"))
			fields.push({
				name : "realEntry",
				doc: ' for "Malloc.calcEntrySize(entry)", or "Ram.free(entry)"',
				access: [AInline, APublic],
				kind: FFun({
					args: [],
					ret : macro :mem.Ptr,
					expr: macro {
						return $i{context} + OFFSET_FIRST;
					}
				}),
				pos: here()
			});


		if (!all_in_map.exists("free"))
			fields.push({
				name : "free",
				doc: ' == .free( this.realEntry() );',
				access: [AInline, APublic],
				kind: FFun({
					args: [],
					ret : null,
					expr: macro {
						$p{mem.free}(realEntry());
						$i{context} = cast mem.Malloc.NUL;
					}
				}),
				pos: here()
			});

		if (!all_in_map.exists("isNull"))
			fields.push({
				name : "isNull",
				doc: ' $context == 0',
				access: [AInline, APublic],
				kind: FFun({
					args: [],
					ret : macro :Bool,
					expr: macro {
						return ($i{context}: Ptr) == mem.Malloc.NUL;
					}
				}),
				pos: here()
			});

		if (abs_type == null && all_in_map.exists(context) == false) { //  for class Some implements Struct{}
			fields.push({
				name : context,
				access: [APublic],
				kind: FProp("default", "null",macro :mem.Ptr),
				pos: here()
			});
		}

		var checkFail = abs_type == null ?  (macro null) : (macro if ((this:Int) <= 0) return null);
		var block:Array<Expr> = [];
		for (k in all_fields) {
			var node = Reflect.field(attrs, k);
			var _w = Ut.hexWidth(offset);
			var _dx  = node.offset        >= 0 ? "0x" + hex( node.offset, _w       ) : "(" + (node.offset       ) + ")";
			var _len = node.len * node.bytes;
			var _end = node.offset + _len >= 0 ? "0x" + hex( node.offset + _len, _w) : "(" + (node.offset + _len) + ")";
			block.push(macro buf.push("offset: " + $v{_dx} + " - " + $v{_end} + ", bytes: "+ $v{_len} +", " + $v{k} + ": " + $i{k} + "\n"));
		}
		var clsname = abs_type == null ? cls.name : abs_type.name;
		fields.push({
			name : "__toOut",
			meta: [{name: ":dce", pos: here()}],
			access: [AInline, APublic],
			kind: FFun({
				args: [],
				ret : macro :String,
				expr: macro {
					$checkFail;
					var actual_space = "";
					if ($v{clsname} != "Block") @:privateAccess {
						var b = mem.Malloc.indexOf($i{ context } + OFFSET_FIRST);
						if (b != mem.Malloc.NUL) // if the "Ptr" is not directly allocated by "malloc" so "b" is Null
							actual_space = "ACTUAL_SPACE: " + (b.size - mem.Malloc.Block.CAPACITY) + ", ";
					}
					var buf = ["\n--- " + $v { clsname } + ".CAPACITY: " + $i { "CAPACITY" } + ", OFFSET_FIRST: " + OFFSET_FIRST
						+ ", OFFSET_END: " + OFFSET_END
						+ "\n--- " + actual_space + "baseAddr: " + ($i{ context } + OFFSET_FIRST) + "\n"];
					$a{block};
					return buf.join("");
				}
			}),
			pos: here()
		});

		}
		return fields;
	}
#end
}