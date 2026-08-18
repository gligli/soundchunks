# Echo server program
import socket

HOST = 'localhost'       # Symbolic name meaning all available interfaces
PORT = 1040              # Arbitrary non-privileged port
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.bind((HOST, PORT))
    s.listen(1)
    conn, addr = s.accept()
    with conn:
        print('Connected by', addr)
        width = 0
        while True:
            data = conn.recv(1)
            if not data:
                continue
            print(data.hex(), end = ' ', flush = True)
            width += 1
            if width >= 32:
                width = 0
                print()
