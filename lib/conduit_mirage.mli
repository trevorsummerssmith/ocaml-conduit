(*
 * Copyright (c) 2012-2014 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

(** Functorial connection establishment interface that is compatible with
    the Mirage libraries.
  *)

type vchan_port = Vchan.Port.t with sexp

(** Configuration for a single client connection *)
type client = [
  | `TLS of Tls.Config.client * client
  | `TCP of Ipaddr.t * int     (** IP address and TCP port number *)
  | `Vchan_direct of int * vchan_port (** Remote Xen domain id and port name *)
  | `Vchan_domain_socket of [ `Uuid of string ] * [ `Port of vchan_port ]
] with sexp

(** Configuration for listening on a server port. *)
type server = [
  | `TLS of Tls.Config.server * server
  | `TCP of [ `Port of int ]
  | `Vchan_direct of [ `Remote_domid of int ] * vchan_port
  | `Vchan_domain_socket of [ `Uuid of string ] * [ `Port of vchan_port ]
] with sexp

(** Module type of a Vchan endpoint *)
module type ENDPOINT = sig

  (** Type of a single connection *)
  type t with sexp_of

  (** Type of the port name that identifies a unique connection at an
      endpoint *)
  type port = vchan_port

  type error = [
    `Unknown of string
  ]

  (** [server ~domid ~port ?read_size ?write_size ()] will listen on a
      connection for a source [domid] and [port] combination, block
      until a client connects, and then return a {!t} handle to read
      and write on the resulting connection.  The size of the shared
      memory buffer can be controlled by setting [read_size] or
      [write_size] in bytes. *)
  val server :
    domid:int ->
    port:port ->
    ?read_size:int ->
    ?write_size:int ->
    unit -> t Lwt.t

  (** [client ~domid ~port ()] will connect to a remote [domid] and
    [port] combination, where a server should already be listening
    after making a call to {!server}.  The call will block until a
    connection is established, after which it will return a {!t}
    handle that can be used to read or write on the shared memory
    connection. *)
  val client :
    domid:int ->
    port:port ->
    unit -> t Lwt.t

  (** Close a Vchan. This deallocates the Vchan and attempts to free
      its resources. The other side is notified of the close, but can
      still read any data pending prior to the close. *)
  val close : t -> unit Lwt.t

  include V1_LWT.FLOW
    with type flow = t
    and  type error := error
    and  type 'a io = 'a Lwt.t
    and  type buffer = Cstruct.t
end

module type PEER = sig
  type t with sexp_of
  type flow with sexp_of
  type uuid with sexp_of
  type port with sexp_of

  module Endpoint : ENDPOINT

  val register : uuid -> t Lwt.t

  val listen : t -> Conduit.endp Lwt_stream.t Lwt.t

  val connect : t -> remote_name:uuid -> port:port -> Conduit.endp Lwt.t

end

module Dynamic_flow : V1_LWT.FLOW

module type VCHAN_PEER = PEER
  with type uuid = string
   and type port = vchan_port

type unknown = [ `Unknown of string ]
module type VCHAN_FLOW = V1_LWT.FLOW
  with type error := unknown

module type TLS = sig
  module FLOW : V1_LWT.FLOW   (* Underlying (encrypted) flow *)
    with type flow = Dynamic_flow.flow
  include V1_LWT.FLOW
  type tracer
  val server_of_flow :
    ?trace:tracer ->
    Tls.Config.server -> FLOW.flow ->
    [> `Ok of flow | `Error of error | `Eof  ] Lwt.t
  val client_of_flow: Tls.Config.client -> FLOW.flow ->
    [> `Ok of flow | `Error of error | `Eof] Lwt.t
end

module No_TLS : TLS
(** Dummy TLS module which can be used if you don't want TLS support. *)

module type S = sig

  module Flow : V1_LWT.FLOW
  type +'a io = 'a Lwt.t
  type ic = Flow.flow
  type oc = Flow.flow
  type flow = Flow.flow
  type stack
  type peer

  type ctx with sexp_of
  val default_ctx : ctx

  val init : ?peer:peer -> ?stack:stack -> unit -> ctx io

  val connect : ctx:ctx -> client -> (flow * ic * oc) io

  val serve :
    ?timeout:int -> ?stop:(unit io) -> ctx:ctx ->
     mode:server -> (flow -> ic -> oc -> unit io) -> unit io

  val endp_to_client: ctx:ctx -> Conduit.endp -> client io
  (** Use the configuration of the server to interpret how to handle a
      particular endpoint from the resolver into a concrete
      implementation of type [client] *)

  val endp_to_server: ctx:ctx -> Conduit.endp -> server io
end

module Make(S:V1_LWT.STACKV4)(V: VCHAN_PEER)(T:TLS) :
  S with type stack = S.t
     and type peer = V.t
