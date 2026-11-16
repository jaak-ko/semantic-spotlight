# One request to a daemon in a given HOME: req_socket.py <home> '<json request>'. Prints the reply line.
import json, socket, sys

home, request = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX)
s.settimeout(300)
s.connect(home + "/.semsearch/daemon.sock")
s.sendall((request + "\n").encode())
print(s.makefile().readline().strip())
