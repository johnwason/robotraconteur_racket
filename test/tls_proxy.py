"""TLS-terminating TCP relay for testing rr+wss without network access.

Usage: python3 tls_proxy.py LISTEN_PORT TARGET_PORT CERT_PEM KEY_PEM

Accepts TLS on LISTEN_PORT (localhost, IPv4 and IPv6 when available) and
relays the decrypted bytes to 127.0.0.1:TARGET_PORT, where a plain
rr+ws-capable Robot Raconteur service is listening. This stands in for the
reverse proxy that usually provides wss:// in front of a node.
"""
import socket
import ssl
import sys
import threading


def relay(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(client, ctx, target_port):
    try:
        tls = ctx.wrap_socket(client, server_side=True)
    except (ssl.SSLError, OSError):
        # e.g. the client rejected our certificate
        client.close()
        return
    upstream = socket.create_connection(("127.0.0.1", target_port))
    threading.Thread(target=relay, args=(tls, upstream), daemon=True).start()
    threading.Thread(target=relay, args=(upstream, tls), daemon=True).start()


def main():
    listen_port, target_port = int(sys.argv[1]), int(sys.argv[2])
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(sys.argv[3], sys.argv[4])
    if socket.has_dualstack_ipv6():
        srv = socket.create_server(("::", listen_port), family=socket.AF_INET6, dualstack_ipv6=True)
    else:
        srv = socket.create_server(("127.0.0.1", listen_port))
    print("READY", flush=True)
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client, ctx, target_port), daemon=True).start()


if __name__ == "__main__":
    main()
