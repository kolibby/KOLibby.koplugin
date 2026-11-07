#!/usr/bin/env python3
# Copyright (C) 2026 KOLibby contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Local TLS fixture for stock KOReader; accepts synthetic requests only.

Run with --cert/--key for a localhost SAN certificate; trust that certificate
only in the test Transport instance. Forward the port with adb reverse.
"""
import argparse
import gzip
import json
import ssl
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--cert', required=True)
parser.add_argument('--key', required=True)
parser.add_argument('--log', type=Path, required=True)
parser.add_argument('--port', type=int, default=19443)
args = parser.parse_args()
BODY = 'Wire fixture café 🌍\n'.encode() * 3000


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def respond(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length) if length else b''
        with args.log.open('a') as output:
            output.write(json.dumps(dict(path=self.path, method=self.command,
                protocol=self.request_version, headers=dict(self.headers),
                body_bytes=len(body), client_port=self.client_address[1])) + '\n')
        encoded = BODY
        coding = None
        if self.path in ('/gzip', '/chunked', '/stale', '/truncated', '/limit'):
            encoded = gzip.compress(BODY, mtime=0)
            coding = 'gzip'
        elif self.path == '/deflate':
            encoded = zlib.compress(BODY)
            coding = 'deflate'
        elif self.path == '/unsupported':
            coding = 'unsupported'
        if self.path == '/truncated':
            encoded = encoded[:-1]
        self.send_response(200)
        if coding:
            self.send_header('Content-Encoding', coding)
        if self.path == '/chunked':
            self.send_header('Transfer-Encoding', 'chunked')
        else:
            self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        if self.path == '/chunked':
            for offset in range(0, len(encoded), 7):
                chunk = encoded[offset:offset+7]
                self.wfile.write(f'{len(chunk):x}\r\n'.encode()+chunk+b'\r\n')
            self.wfile.write(b'0\r\n\r\n')
        else:
            self.wfile.write(encoded)
        self.wfile.flush()
        if self.path == '/stale':
            self.close_connection = True  # Simulate an unannounced idle close.

    def log_message(self, *unused):
        pass


context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(args.cert, args.key)
server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
server.socket = context.wrap_socket(server.socket, server_side=True)
print('TLS fixture ready', flush=True)
server.serve_forever()
