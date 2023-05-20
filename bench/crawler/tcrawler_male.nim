discard """
  action: "compile"
"""

# Simple web crawler that uses `spawn` for parallel downloads and parsing.

import malebolgia
#import experiment / malebolgia_push
import malebolgia / ticketlocks

import std / [isolation, os, streams, parsexml, strutils, sets, times]

const
  StartUrl = "https://nim-lang.org"

proc cut(s: string): string =
  let p = find(s, '#')
  if p >= 0:
    result = s.substr(0, p-1)
  else:
    result = s

proc combine(url, base: string): string =
  if url.endsWith(".tar.xz") or url.endsWith(".zip") or url.endsWith(".7z"):
    result = ""
  elif url.startsWith(base):
    result = url.cut
  elif url.startsWith("/"):
    result = (base & url).cut
  elif not url.startsWith("http"):
    result = (base & "/" & url).cut
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

proc download(url: string; master: MasterHandle) {.gcsafe.}

proc `=?=` (a, b: string): bool =
  return cmpIgnoreCase(a, b) == 0

proc extractLinks(html: string; master: MasterHandle) {.gcsafe.} =
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
                master.spawn download(link, master)
        else:
          x.next()
      of xmlEof: break # end of file reached
      of xmlError:
        #echo(errorMsg(x))
        x.next()
      else: x.next() # skip other events

  #echo($links & " link(s) found!")
  x.close()

proc mangle(url: string): string =
  url.multiReplace({"/": "_", ".html": "", ".": "", ":": ""}) & ".html"

proc download(url: string; master: MasterHandle) =
  let filename = "bench/data/" & url.mangle
  try:
    let content = readFile(filename)
    if content.len > 0:
      master.spawn extractLinks(content, master)
  except:
    #echo "could not find ", filename
    discard

seen.incl StartUrl

import std / monotimes

let t0 = getMonoTime()

for i in 0..<parseInt(paramStr(1)):
  seen = initHashSet[string]()
  seen.incl StartUrl
  var master = createMaster() #timeout=initDuration(seconds=10))
  master.awaitAll:
    master.spawn download(StartUrl, getHandle master)

echo "took ", getMonoTime() - t0
echo "seen links ", seen.len

# took 834 milliseconds and 679 microseconds
# seen links 46
