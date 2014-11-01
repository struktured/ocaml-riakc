

module type Key = sig include Protobuf_capable.S end
module type Value = sig include Protobuf_capable.S end

module E = Protobuf.Encoder

let wrap_request (mc:'a) s =
  (* Add 1 for the mc *)
  let l = Bytes.length s + 1 in
  let preamble_mc = Bytes.create 5 in
  Bytes.set preamble_mc 0 (Core.Std.Char.of_int_exn ((l lsr 24) land 0xff));
  Bytes.set preamble_mc 1 (Core.Std.Char.of_int_exn ((l lsr 16) land 0xff));
  Bytes.set preamble_mc 2 (Core.Std.Char.of_int_exn ((l lsr 8) land 0xff));
  Bytes.set preamble_mc 3 (Core.Std.Char.of_int_exn (l land 0xff));
  Bytes.set preamble_mc 4 mc;
  preamble_mc ^ s
type error = [`Unknown]
let ping () =
  Core.Std.Result.Ok (wrap_request '\x01' "")

let client_id () =
  Core.Std.Result.Ok (wrap_request '\x03' "")

let server_info () =
  Core.Std.Result.Ok (wrap_request '\x07' "")

let bucket_props bucket () =
  let open Core.Std.Result.Monad_infix in
  let e = E.create () in
  E.bytes bucket e;
  Core.Std.Result.Ok (wrap_request '\x13' (E.to_string e))

let list_buckets () =
   Core.Std.Result.Ok (wrap_request '\x0F' "")

let list_keys bucket () =
  let open Core.Std.Result.Monad_infix in
  let e = E.create () in
  E.bytes bucket e; 
  Core.Std.Result.Ok (wrap_request '\x11' (E.to_string e))

module Make(Key:Key) (Value:Value) = 
  struct
let get g () =
  let module Get = Opts.Get(Key) in
  let open Get in 
  let open Core.Std.Result.Monad_infix in
  let e = E.create () in 
  Get.get_to_protobuf g e;
  Core.Std.Ok (wrap_request '\x09' (E.to_string e))

let put p () =
  let module Put = Opts.Put (Key) (Value) in
  let module Content = Robj.Content(Key) (Value) in
  let open Put in
  let e = E.create () in
  Put.put_to_protobuf p e;
  Core.Std.Ok (wrap_request '\x0E' (E.to_string e))

let delete d () =
  let module Delete = Opts.Delete (Key) in
  let open Delete in
  let open Core.Std.Result.Monad_infix in
  let e = E.create () in
  Delete.delete_to_protobuf d e; 
(*  E.bytes     b 1 d.bucket >>= fun () ->
          let msg = E.embd_msg b 2 d.key in 
          msg
          >>= fun () ->
  E.int32_opt b 3 d.rw     >>= fun () ->
  E.bytes_opt b 4 d.vclock >>= fun () ->
  E.int32_opt b 5 d.r      >>= fun () ->
  E.int32_opt b 6 d.w      >>= fun () ->
  E.int32_opt b 7 d.pr     >>= fun () ->
  E.int32_opt b 8 d.pw     >>= fun () ->
  E.int32_opt b 9 d.dw     >>= fun () ->
  *) 
  Core.Std.Result.Ok (wrap_request '\x0D' (E.to_string e))

type decorated_index_search = {
    bucket: bytes [@key 1];
    idx : bytes [@key 2];
    query_type : Opts.Index_search.Query.t [@key 3];
    key: (* Key.t *) string option [@key 4];
    min : bytes option [@key 5];
    max : bytes option [@key 6];
    rt : bool option [@key 7];
    stream : bool [@key 8];
    max_results: int option [@key 9];
    cont: bytes option [@key 10]
  } [@@deriving protobuf]


let index_search ~stream idx_s () =
  let open Opts.Index_search in
  let determine_index idx_s =
    match idx_s.query_type with
      | Query.Eq_int _
      | Query.Range_int _ ->
	idx_s.index ^ "_int"
      | Query.Eq_string _
      | Query.Range_string _ ->
	idx_s.index ^ "_bin"
  in
  let determine_key idx_s =
    match idx_s.query_type with
      | Query.Eq_int i ->
	Some (Core.Std.Int.to_string i)
      | Query.Eq_string s ->
	Some s
      | Query.Range_int _
      | Query.Range_string _ ->
	None
  in
  let determine_min idx_s =
    match idx_s.query_type with
      | Query.Range_int { Query.min = min_i } ->
	Some (Core.Std.Int.to_string min_i)
      | Query.Range_string { Query.min = min_s } ->
	Some min_s
      | Query.Eq_int _
      | Query.Eq_string _ ->
	None
  in
  let determine_max idx_s =
    match idx_s.query_type with
      | Query.Range_int { Query.max = max_i } ->
	Some (Core.Std.Int.to_string max_i)
      | Query.Range_string { Query.max = max_s } ->
	Some max_s
      | Query.Eq_int _
      | Query.Eq_string _ ->
	None
  in
  let determine_rt idx_s =
    match idx_s.query_type with
      | Query.Range_string r ->
	Some r.Query.return_terms
      | Query.Range_int r ->
	Some r.Query.return_terms
      | Query.Eq_string _
      | Query.Eq_int _ ->
	None
  in
  let determine_cont idx_s =
    Core.Std.Option.map ~f:Kontinuation.to_string idx_s.continuation
  in
  let query_type_conv = function
    | Query.Eq_string _
    | Query.Eq_int _ ->
      Core.Std.Ok 0
    | Query.Range_string _
    | Query.Range_int _ ->
      Core.Std.Ok 1
  in
  let idx  = determine_index idx_s in
  let key  = determine_key   idx_s in
  let min  = determine_min   idx_s in
  let max  = determine_max   idx_s in
  let rt   = determine_rt    idx_s in
  let cont = determine_cont  idx_s in
  let e    = E.create () in
  let open Core.Std.Result.Monad_infix in
  let decorated = {bucket=idx_s.bucket;idx;key;min;max;rt;cont;stream;max_results=idx_s.max_results;query_type=idx_s.query_type} in
  decorated_index_search_to_protobuf decorated e;
  (*E.bytes     b  1 idx_s.bucket                     >>= fun () ->
  E.bytes     b  2 idx                              >>= fun () ->
  E.enum      b  3 idx_s.query_type query_type_conv >>= fun () ->
  E.bytes_opt b  4 key                              >>= fun () ->
  E.bytes_opt b  5 min                              >>= fun () ->
  E.bytes_opt b  6 max                              >>= fun () ->
  E.bool_opt  b  7 rt                               >>= fun () ->
  E.bool      b  8 stream                           >>= fun () ->
  E.int32_opt b  9 idx_s.max_results                >>= fun () ->
  E.bytes_opt b 10 cont                             >>= fun () ->
  *)Core.Std.Result.Ok (wrap_request '\x19' (E.to_string e))
end

