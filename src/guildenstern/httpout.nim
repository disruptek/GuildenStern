import posix, net, nativesockets, os, httpcore, streams
import guildenserver
from strutils import join

{.push checks: off.}

proc writeToHttp*(fd: posix.SocketHandle, text: string, length: int = -1): string =
  var length = length
  if length == -1: length = text.len
  if length == 0: return
  var bytessent = 0
  var retries = 0
  while bytessent < length:
    let ret =
      try: send(fd, unsafeAddr text[bytessent], length - bytessent, 0)
      except: return getCurrentExceptionMsg()
    if ret != length: echo "kaikki ei lähteny ", ret, "/", length
    if ret == -1: return "send returned -1"
    if ret == 0:
      retries.inc(10)
      echo "backoff triggered"
      sleep(retries)
      # TODO: real backoff strategy
    retries.inc
    if retries > 100: return "posix does not send"
    bytessent.inc(ret)
  return ""


proc doReply*(fd: SocketHandle, code: HttpCode, body: string, headers=""): string = # TODO: send headers first?
  let theheaders = if likely(headers.len == 0): "" else: "\c\L" & headers
  let text = "HTTP/1.1 " & $code & "\c\L" & "Content-Length: " & $body.len & theheaders & "\c\L\c\L" & body
  return writeToHttp(fd, text)


proc joinHeaders(headers: openArray[seq[string]]): string {.inline.} =
  for x in headers.low .. headers.high:
    for y in headers[x].low .. headers[x].high:
      if y > 0 or x > 0: result.add("\c\L")
      result.add(headers[x][y])


proc reply*(c: GuildenVars, code: HttpCode, body: string, headers="") {.inline.} =
  discard doReply(c.fd, code,  body, headers)


proc reply*(c: GuildenVars, code: HttpCode, body: string, headers: openArray[string]) {.inline.} =
  discard doReply(c.fd, code,  body, headers.join("\c\L"))


proc reply*(c: GuildenVars, code: HttpCode, body: string, headers: seq[string]) {.inline.} =
  discard doReply(c.fd, code,  body, headers.join("\c\L"))


proc reply*(c: GuildenVars, code: HttpCode, body: string,  headers: openArray[seq[string]]) {.inline.} =
  discard doReply(c.fd, code,  body, joinHeaders(headers))


proc reply*(c: GuildenVars, body: string, code=Http200) {.inline.} =
  discard doReply(c.fd, code, body)

# HeadersOnly??

proc doReplyHeaders*(fd: posix.SocketHandle, code: HttpCode=Http200, headers=""): string =
  var head = "HTTP/1.1 " & $code & "\c\L" & "Content-Length: 0\c\L"
  if headers.len > 0: head.add(headers & "\c\L")
  head.add("\c\L")
  return writeToHttp(fd, head)
  

proc replyHeaders*(c: GuildenVars, headers: openArray[string], code: HttpCode=Http200) {.inline.} =
  discard doReplyHeaders(c.fd, code, headers.join("\c\L"))


proc replyHeaders*(c: GuildenVars, headers: seq[string], code: HttpCode=Http200) {.inline.} =
  discard doReplyHeaders(c.fd, code, headers.join("\c\L"))


proc replyHeaders*(c: GuildenVars, headers: openArray[seq[string]], code: HttpCode=Http200) {.inline.} =
  discard doReplyHeaders(c.fd, code, joinHeaders(headers))

# varri poissa käytöstä

proc doReply*(c: GuildenVars, code: HttpCode=Http200, headers=""): bool =
  let length = c.sendbuffer.getPosition()
  let headers = if likely(headers.len == 0): "HTTP/1.1 " & $code & "\c\L" & "Content-Length: " & $length & "\c\L\c\L"
  else: "HTTP/1.1 " & $code & "\c\L" & "Content-Length: " & $length & "\c\L" & headers & "\c\L\c\L"
  c.currentexceptionmsg = writeToHttp(c.fd, headers)
  if c.currentexceptionmsg == "": c.currentexceptionmsg = writeToHttp(c.fd, c.sendbuffer.data, length)
  return c.currentexceptionmsg == ""


proc reply*(c: GuildenVars, headers: openArray[string]) {.inline.} =
  discard doReply(c, Http200, headers.join("\c\L"))


proc reply*(c: GuildenVars, headers: seq[string]) {.inline.} =
  discard doreply(c, Http200, headers.join("\c\L"))


proc reply*(c: GuildenVars, headers: openArray[seq[string]]) {.inline.} =
  discard doreply(c, Http200, joinHeaders(headers))


proc replyCode*(c: GuildenVars, code: HttpCode) {.inline.} =
  discard doReplyHeaders(c.fd, code)

{.pop.}