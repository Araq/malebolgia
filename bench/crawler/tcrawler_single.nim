discard """
  action: "compile"
"""

# Simple web crawler that uses `spawn` for parallel downloads and parsing.

import malebolgia / ticketlocks

import std / [isolation, httpclient, os, streams, parsexml, strutils, sets, times]

const
  StartUrl = "https://nim-lang.org"

proc combine(url, base: string): string =
  if url.endsWith(".tar.xz") or url.endsWith(".zip") or url.endsWith(".7z"):
    result = ""
  elif url.startsWith(base):
    result = url
  elif url.startsWith("/"):
    result = base & url
  elif not url.startsWith("http"):
    result = base & "/" & url
  else:
    result = ""

var
  seen: HashSet[string]
  L: TicketLock

proc containsOrIncl(s: string): bool =
  {.gcsafe.}:
    acquire L
    result = containsOrIncl(seen, s)
    release L

proc download(url: string) {.gcsafe.}

proc `=?=` (a, b: string): bool =
  return cmpIgnoreCase(a, b) == 0

proc extractLinks(html: string) {.gcsafe.} =
  var links = 0 # count the number of links
  var s = newStringStream(html)
  var x: XmlParser
  open(x, s, "<content.html>")
  next(x) # get first event
  block mainLoop:
    while true:
      case x.kind
      of xmlElementOpen:
        # the <a href = "xyz"> tag we are interested in always has an attribute,
        # thus we search for ``xmlElementOpen`` and not for ``xmlElementStart``
        if x.elementName =?= "a":
          x.next()
          if x.kind == xmlAttribute:
            if x.attrKey =?= "href":
              var link = x.attrValue
              inc(links)
              # skip until we have an ``xmlElementClose`` event
              while true:
                x.next()
                case x.kind
                of xmlEof: break mainLoop
                of xmlElementClose: break
                else: discard
              x.next() # skip ``xmlElementClose``
              # now we have the description for the ``a`` element
              var desc = ""
              while x.kind == xmlCharData:
                desc.add(x.charData)
                x.next()
              link = combine(link, StartUrl)
              if link.len > 0 and not containsOrIncl(link):
                download(link)
        else:
          x.next()
      of xmlEof: break # end of file reached
      of xmlError:
        #echo(errorMsg(x))
        x.next()
      else: x.next() # skip other events

  echo($links & " link(s) found!")
  x.close()


proc download(url: string) =
  echo "downloading ", url
  var client = newHttpClient()
  var content = ""
  try:
    content = client.getContent(url)
  except HttpRequestError:
    discard
  finally:
    client.close()
  if content.len > 0:
    extractLinks(content)

seen.incl StartUrl

import std / times

let t0 = getTime()

download(StartUrl)
echo "took ", getTime() - t0

# took 1 minute, 19 seconds, 717 milliseconds, 426 microseconds, and 300 nanoseconds

