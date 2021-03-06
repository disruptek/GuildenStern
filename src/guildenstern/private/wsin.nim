import nativesockets, net, posix, streams, os
from ../guildenserver import ServerState, MaxRequestLength, GuildenVars

type
  WebSocketError* = object of CatchableError

{.push checks: off.}

template `[]`(value: uint8, index: int): bool =
  ## Get bits from uint8, uint8[2] gets 2nd bit.
  (value and (1 shl (7 - index))) != 0


type
  Opcode* = enum
    ## 4 bits. Defines the interpretation of the "Payload data".
    Cont = 0x0                ## denotes a continuation frame
    Text = 0x1                ## denotes a text frame
    Binary = 0x2              ## denotes a binary frame
    # 3-7 are reserved for further non-control frames
    Close = 0x8               ## denotes a connection close
    Ping = 0x9                ## denotes a ping
    Pong = 0xa                ## denotes a pong
    # B-F are reserved for further control frames
    Fail = 0xe                ## denotes failure

  #[
   0                   1                   2                   3
   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
  +-+-+-+-+-------+-+-------------+-------------------------------+
  |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
  |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
  |N|V|V|V|       |S|             |   (if payload len==126/127)   |
  | |1|2|3|       |K|             |                               |
  +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
  |     Extended payload length continued, if payload len == 127  |
  + - - - - - - - - - - - - - - - +-------------------------------+
  |                               |Masking-key, if MASK set to 1  |
  +-------------------------------+-------------------------------+
  | Masking-key (continued)       |          Payload Data         |
  +-------------------------------- - - - - - - - - - - - - - - - +
  :                     Payload Data continued ...                :
  + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
  |                     Payload Data continued ...                |
  +---------------------------------------------------------------+]#


proc bytesRecv(fd: posix.SocketHandle, buffer: ptr char, size: int): int =
  return recv(fd, buffer, size, 0.cint)


proc recvHeader(gv: GuildenVars): (Opcode , int) =
  if gv.fd.bytesRecv(gv.wsrecvheader[0].addr, 2) != 2: raise newException(WebSocketError, "No data received")
  let b0 = gv.wsrecvheader[0].uint8
  let b1 = gv.wsrecvheader[1].uint8
  result[0] = (b0 and 0x0f).Opcode
  if b0[1] or b0[2] or b0[3]: raise newException(WebSocketError, "WebSocket Protocol mismatch")

  var expectedLen: int = 0

  let headerLen = uint(b1 and 0x7f)
  if headerLen == 0x7e: # Length must be 7+16 bits.
    var lenstrlen = gv.fd.bytesRecv(gv.wsrecvheader[0].addr, 2)
    if lenstrlen != 2: raise newException(WebSocketError, "Socket closed")
    expectedLen = nativesockets.htons(cast[ptr uint16](gv.wsrecvheader[0].addr)[]).int
  elif headerLen == 0x7f: # Length must be 7+64 bits.
    var lenstrlen = gv.fd.bytesRecv(gv.wsrecvheader[0].addr, 8)
    if lenstrlen != 8: raise newException(WebSocketError, "Socket closed")
    expectedLen = nativesockets.htonl(cast[ptr uint32](gv.wsrecvheader[4].addr)[]).int
  else: # Length must be 7 bits.
    expectedLen = headerLen.int

  let maskKeylen = gv.fd.bytesRecv(gv.wsrecvheader[0].addr, 4)
  if maskKeylen != 4: raise newException(WebSocketError, "Socket closed")

  if gv.recvbuffer.getPosition() + expectedLen > MaxRequestLength:
    raise newException(WebSocketError, "Maximum request size bound to be exceeded: " & $(gv.recvbuffer.getPosition() + expectedLen))

  result[1] = expectedLen


proc recvFrame(gv: GuildenVars): OpCode =
  var expectedlen: int  
  (result , expectedlen) = gv.recvHeader()
  if result == Opcode.Close: return
  var recvbufferlen = gv.recvbuffer.getPosition()
  var trials = 0
  while true:
    let ret = recv(gv.fd, addr gv.recvbuffer.data[recvbufferlen], expectedlen - recvbufferlen, 0.cint)
    if gv.gs.serverstate == Shuttingdown: return Fail
    if ret > 0:
      trials = 0
      recvbufferlen += ret
      if recvbufferlen == expectedlen:
        try: gv.recvbuffer.setPosition(expectedlen) # - 1 ?
        except: echo("recvbuffer setPosition error")
        return
      continue
    let lastError = osLastError()
    if ret < 0: raise newException(WebSocketError, $lastError & " = " & osErrorMsg(lastError))
    if trials >= 4: raise newException(WebSocketError, "Socket unrepsonsive")
    if lastError == 0.OsErrorCode or lastError == 2.OsErrorCode or lastError == 9.OsErrorCode or lastError == 104.OsErrorCode:
      raise newException(WebSocketError, $lastError & " = " & osErrorMsg(lastError))
    trials.inc
    echo "backoff triggered"
    sleep(100 + trials * 100) # TODO: real backoff strategy

 
proc readFromWs*(gv: GuildenVars): Opcode =
  try:
    result = gv.recvFrame()
    if result == Close: return Close
    while result == Cont: result = gv.recvFrame()
    let len = gv.recvbuffer.getPosition()
    for i in 0 ..< len: gv.recvbuffer.data[i] = (gv.recvbuffer.data[i].uint8 xor gv.wsrecvheader[i mod 4].uint8).char
  except:
    try: gv.recvbuffer.setPosition(0)
    except: discard
    gv.currentexceptionmsg = "websocket receive: " & getCurrentExceptionMsg()
    result = Fail

{.pop.}