"""TCP server that accepts connections and never sends anything.

Usage: python3 hung_server.py PORT

Stands in for a service that is up but not answering (or a typo'd port that
some other program owns). Prints "READY", then "accept N" when connection N
arrives and "closed N" when the client closes it, so tests can check that a
timed-out connect really closed its socket.
"""
import socket
import sys
import threading

srv = socket.create_server(("127.0.0.1", int(sys.argv[1])))
print("READY", flush=True)
n = 0


def drain(c, i):
    try:
        while c.recv(65536):
            pass
    except OSError:
        pass
    print("closed", i, flush=True)


while True:
    c, _ = srv.accept()
    n += 1
    print("accept", n, flush=True)
    threading.Thread(target=drain, args=(c, n), daemon=True).start()
