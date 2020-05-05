# https://github.com/wg/wrk/wiki/Installing-Wrk-on-Linux
# nim c -r --threads:on --d:threadsafe --d:danger guildentest.nim
# nim c -r --threads:on --d:threadsafe --d:danger beasttest.nim

wrk -t5 -c5 -d10s --latency --timeout 10s http://127.0.0.1:8080/plaintext