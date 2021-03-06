open Core.Std
open Async.Std
module String = Core.Std.String


type t = { r : Reader.t
	 ; w : Writer.t
	 }
type error = [ `Bad_conn ]
  
let rec read_str r pos s = 
  Reader.read r ~pos s >>= function
    | `Ok l -> begin
      if (pos + l) <> String.length s then
	read_str r (pos + l) s
      else
	Deferred.return (Ok s)
    end
    | `Eof ->
      Deferred.return (Error `Bad_conn)

let parse_length preamble =
  Deferred.return (Response.parse_length preamble)

let read_payload r preamble =
  let open Deferred.Result.Monad_infix in
  parse_length preamble >>= fun resp_len ->
  let payload = String.create resp_len in
  read_str r 0 payload

let rec read_response r f c =
  let open Deferred.Result.Monad_infix in
  let preamble = String.create 4 in
  read_str r 0 preamble       >>= fun _ ->
  read_payload r preamble     >>= fun payload ->
  Deferred.return (f payload) >>= function
    | Response.More resp ->
      let open Deferred.Monad_infix in
      c resp >>= fun () ->
      read_response r f c
    | Response.Done resp ->
      let open Deferred.Monad_infix in
      c resp >>= fun () ->
      Deferred.return (Ok ())

let do_request_stream t c g f =
  let open Deferred.Result.Monad_infix in
  Deferred.return (g ()) >>= fun request ->
  Writer.write t.w request;
  read_response t.r f c


let do_request t g f =
  let open Deferred.Monad_infix in
  let (r, w) = Pipe.create () in
  let c x    = Pipe.write_without_pushback w x; Deferred.return () in
  do_request_stream t c g f >>= function
    | Ok () -> begin
      Pipe.close w;
      Pipe.to_list r >>| fun l ->
      Ok l
    end
    | Error err ->
      Deferred.return (Error err)

let gen_consumer w = Pipe.write_without_pushback w |> Deferred.return

let connect ~host ~port =
  let connect () =
    Tcp.connect (Tcp.to_host_and_port host port)
  in
  Monitor.try_with connect >>| function
    | Ok (_s, r, w) ->
      Ok { r; w }
    | Error _exn ->
      Error `Bad_conn

let close t =
  Writer.close t.w >>= fun () ->
  Deferred.return (Ok ())

let with_conn ~host ~port f =
  connect host port >>= function
    | Ok c -> begin
      f c    >>= fun r ->
      close c >>= fun _ ->
      Deferred.return r
    end
    | Error err ->
      Deferred.return (Error err)

let ping t =
  do_request
    t
    Request.ping
    Response.ping
  >>| function
    | Ok [()] ->
      Ok ()
    | Ok _ ->
      Error `Wrong_type
    | Error err ->
      Error err

let client_id t =
  do_request
    t
    Request.client_id
    Response.client_id
  >>| function
    | Ok [client_id] ->
      Ok client_id
    | Ok _ ->
      Error `Wrong_type
    | Error err ->
      Error err

let server_info t =
  do_request
    t
    Request.server_info
    Response.server_info
  >>| function
    | Ok [(node, version)] ->
      Ok (node, version)
    | Ok _ ->
      Error `Wrong_type
    | Error err ->
      Error err

let bucket_props t bucket =
  do_request
    t
    (Request.bucket_props bucket)
    Response.bucket_props
  >>| function
    | Ok [props] ->
      Ok props
    | Ok _ ->
      Error `Wrong_type
    | Error err ->
      Error err

let list_buckets t =
  do_request
    t
    Request.list_buckets
    Response.list_buckets
  >>| function
      Ok [buckets] ->
      Ok buckets
    | Ok _ ->
      Error `Wrong_type
    | Error err ->
      Error err


let list_keys_stream t bucket consumer =
  do_request_stream
    t
    consumer
    (Request.list_keys bucket)
    Response.list_keys

let list_keys t bucket =
  do_request
    t
    (Request.list_keys bucket)
    Response.list_keys
  >>| function
    | Ok keys ->
      Ok (List.concat keys)
    | Error err ->
      Error err

let get t ?(opts = []) ~b k =
  do_request
    t
    (Request.get (Opts.Get.get_of_opts opts ~b ~k))
    Response.get
  >>| function
    | Ok [robj] -> begin
      if Robj.contents robj = [] && Robj.vclock robj = None then
	Error `Notfound
      else
	Ok robj
    end
    | Ok _ ->
      Error `Wrong_type
    | Error err ->
      Error err

let put t ?(opts = []) ~b ?k robj =
  do_request
    t
    (Request.put (Opts.Put.put_of_opts opts ~b ~k robj))
    Response.put
  >>| function
    | Ok [(robj, key)] ->
      Ok (robj, key)
    | Ok _ ->
      Error `Wrong_type
    | Error err ->
      Error err

let delete t ?(opts = []) ~b k =
  do_request
    t
    (Request.delete (Opts.Delete.delete_of_opts opts ~b ~k))
    Response.delete
  >>| function
    | Ok [()] ->
      Ok ()
    | Ok _ ->
      Error `Wrong_type
    | Error err ->
      Error err

let index_search t ?(opts = []) ~b ~index query_type =
  let idx_s =
    Opts.Index_search.index_search_of_opts
      opts
      ~b
      ~index
      ~query_type
  in
  do_request
    t
    (Request.index_search ~stream:false idx_s)
    Response.index_search
  >>| function
    | Ok [results] ->
      Ok results
    | Ok _ ->
      Error `Wrong_type
    | Error err ->
      Error err

