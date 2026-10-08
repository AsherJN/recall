#!/usr/bin/env python3
"""Authenticode signing for DXMT's DLSS stand-in (nvngx.dll).

NVIDIA's NGX loader loads its core DLL only when the file carries an embedded signature that
WinVerifyTrust accepts; it never checks who signed it. Under Wine an intact signature from
an untrusted root passes (tested 2026-10-06), so Recall signs the stand-in with its own
certificate, made once by this script, rather than a paid one; if Wine ever enforces trust,
the fallback is a CA-issued certificate.

  create-certificate DIR   a "Recall Root" CA and a "Recall" code-signing certificate
                           issued by it (RSA 3072, 20 years). Keys stay outside git under
                           runtime/; losing them only means making new ones.
  sign DIR IN OUT          signs IN (SHA-256 Authenticode) as OUT with DIR's certificate
  check FILE [DIR]         the file carries a signature whose image hash matches its bytes
                           (and, with DIR, that DIR's certificate signed it)

Needs OpenSSL 3 (Homebrew's, or OPENSSL=<path>).
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

KEY, LEAF, ROOT, ROOT_KEY = 'recall.key', 'recall.der', 'recall-root.der', 'recall-root.key'
DAYS = 20 * 365


def openssl():
    for candidate in (os.environ.get('OPENSSL'), '/opt/homebrew/opt/openssl@3/bin/openssl',
                      '/opt/homebrew/bin/openssl', '/usr/local/opt/openssl@3/bin/openssl'):
        if candidate and Path(candidate).is_file():
            return candidate
    raise SystemExit('OpenSSL 3 not found (brew install openssl@3, or set OPENSSL)')


# DER helpers

def der_len(n):
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, 'big')
    return bytes([0x80 | len(b)]) + b


def tlv(tag, content):
    return bytes([tag]) + der_len(len(content)) + content


def seq(*items):
    return tlv(0x30, b''.join(items))


def set_of(*items):
    return tlv(0x31, b''.join(sorted(items)))  # DER: SET OF sorted by encoding


def ctx(n, content):
    return tlv(0xA0 | n, content)


def oid(dotted):
    parts = [int(x) for x in dotted.split('.')]
    body = bytes([40 * parts[0] + parts[1]])
    for p in parts[2:]:
        enc = [p & 0x7F]
        p >>= 7
        while p:
            enc.append(0x80 | (p & 0x7F))
            p >>= 7
        body += bytes(reversed(enc))
    return tlv(0x06, body)


def integer(n):
    b = n.to_bytes(max(1, (n.bit_length() + 7) // 8), 'big')
    if b[0] & 0x80:
        b = b'\x00' + b
    return tlv(0x02, b)


def octets(b):
    return tlv(0x04, b)


NULL = b'\x05\x00'
SHA256 = '2.16.840.1.101.3.4.2.1'
SPC_INDIRECT_DATA = '1.3.6.1.4.1.311.2.1.4'
SPC_PE_IMAGE_DATA = '1.3.6.1.4.1.311.2.1.15'


def read_tlv(buf, off):
    """(tag, content_start, content_end) of the element at OFF."""
    tag, first = buf[off], buf[off + 1]
    if first & 0x80:
        n = first & 0x7F
        length = int.from_bytes(buf[off + 2:off + 2 + n], 'big')
        start = off + 2 + n
    else:
        length, start = first, off + 2
    return tag, start, start + length


def issuer_and_serial(cert):
    """Raw DER of the certificate's issuer Name and serialNumber."""
    _, cs, _ = read_tlv(cert, 0)              # Certificate
    _, off, _ = read_tlv(cert, cs)            # TBSCertificate
    tag, _, end = read_tlv(cert, off)
    if tag == 0xA0:                           # [0] version
        off = end
    _, _, end = read_tlv(cert, off)           # serialNumber
    serial, off = cert[off:end], end
    _, _, off = read_tlv(cert, off)           # signature AlgorithmIdentifier
    _, _, end = read_tlv(cert, off)           # issuer Name
    return cert[off:end], serial


# PE layout

def pe_fields(data):
    """Offsets of the checksum and of the certificate-table directory entry."""
    if data[:2] != b'MZ':
        raise SystemExit('Not a PE file')
    pe = struct.unpack_from('<I', data, 0x3C)[0]
    if data[pe:pe + 4] != b'PE\0\0':
        raise SystemExit('Not a PE file')
    opt = pe + 24
    magic = struct.unpack_from('<H', data, opt)[0]
    return opt + 64, opt + (112 if magic == 0x20B else 96) + 4 * 8


def image_hash(data, checksum_off, certdir_off, end):
    """Authenticode's SHA-256: the file up to END without the checksum and the directory entry."""
    return hashlib.sha256(bytes(data[:checksum_off]) + bytes(data[checksum_off + 4:certdir_off]) +
                          bytes(data[certdir_off + 8:end])).digest()


def pe_checksum(data, checksum_off):
    buf = bytearray(data)
    buf[checksum_off:checksum_off + 4] = b'\0\0\0\0'
    if len(buf) % 2:
        buf.append(0)
    s = sum(struct.unpack('<%dH' % (len(buf) // 2), bytes(buf)))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (s + len(data)) & 0xFFFFFFFF


# Commands

def create_certificate(folder):
    folder = Path(folder)
    if (folder / KEY).exists():
        raise SystemExit(f'{folder} already holds a certificate; it is never replaced in place.')
    folder.mkdir(parents=True, exist_ok=True)
    tool = openssl()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / 'root.cnf').write_text('[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=v3\n'
                                      '[dn]\nCN=Recall Root\n[v3]\nbasicConstraints=critical,CA:TRUE\n'
                                      'keyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n')
        (tmp / 'request.cnf').write_text('[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=Recall\n')
        (tmp / 'leaf.cnf').write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n'
                                      'extendedKeyUsage=codeSigning\nsubjectKeyIdentifier=hash\n'
                                      'authorityKeyIdentifier=keyid\n')
        run = lambda *a: subprocess.run([tool, *map(str, a)], check=True, capture_output=True)
        run('req', '-x509', '-config', tmp / 'root.cnf', '-newkey', 'rsa:3072', '-nodes', '-keyout',
            folder / ROOT_KEY, '-out', tmp / 'root.pem', '-days', DAYS, '-sha256')
        run('req', '-new', '-config', tmp / 'request.cnf', '-newkey', 'rsa:3072', '-nodes', '-keyout', folder / KEY,
            '-out', tmp / 'leaf.csr')
        run('x509', '-req', '-in', tmp / 'leaf.csr', '-CA', tmp / 'root.pem', '-CAkey', folder / ROOT_KEY,
            '-set_serial', '0x' + os.urandom(8).hex(), '-days', DAYS, '-sha256', '-extfile', tmp / 'leaf.cnf',
            '-out', tmp / 'leaf.pem')
        run('x509', '-in', tmp / 'root.pem', '-outform', 'der', '-out', folder / ROOT)
        run('x509', '-in', tmp / 'leaf.pem', '-outform', 'der', '-out', folder / LEAF)
    for name in (KEY, ROOT_KEY):
        (folder / name).chmod(0o600)
    print(f'Created the "Recall" code-signing certificate in {folder}; '
          f'SHA-256 {hashlib.sha256((folder / LEAF).read_bytes()).hexdigest()}')


def sign(folder, src, dst):
    folder = Path(folder)
    data = bytearray(Path(src).read_bytes())
    checksum_off, certdir_off = pe_fields(data)
    old_off, old_size = struct.unpack_from('<II', data, certdir_off)
    if old_size:                              # replace an existing signature
        del data[old_off:]
        struct.pack_into('<II', data, certdir_off, 0, 0)
    while len(data) % 8:
        data.append(0)
    digest = image_hash(data, checksum_off, certdir_off, len(data))

    obsolete = '<<<Obsolete>>>'.encode('utf-16-be')
    pe_image_data = seq(tlv(0x03, b'\x00'), ctx(0, ctx(2, tlv(0x80, obsolete))))
    spc = seq(seq(oid(SPC_PE_IMAGE_DATA), pe_image_data), seq(seq(oid(SHA256), NULL), octets(digest)))
    _, spc_start, _ = read_tlv(spc, 0)
    message_digest = hashlib.sha256(spc[spc_start:]).digest()  # content octets only (PKCS#7 v1.5)
    attributes = set_of(
        seq(oid('1.2.840.113549.1.9.3'), set_of(oid(SPC_INDIRECT_DATA))),                 # contentType
        seq(oid('1.3.6.1.4.1.311.2.1.12'), set_of(seq())),                               # SpcSpOpusInfo
        seq(oid('1.3.6.1.4.1.311.2.1.11'), set_of(seq(oid('1.3.6.1.4.1.311.2.1.21')))),  # individual signing
        seq(oid('1.2.840.113549.1.9.4'), set_of(octets(message_digest))),                 # messageDigest
    )
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / 'attrs.der').write_bytes(attributes)
        subprocess.run([openssl(), 'dgst', '-sha256', '-sign', str(folder / KEY), '-out', f'{tmp}/sig.bin',
                        f'{tmp}/attrs.der'], check=True)
        signature = (Path(tmp) / 'sig.bin').read_bytes()

    leaf = (folder / LEAF).read_bytes()
    issuer, serial = issuer_and_serial(leaf)
    signer_info = seq(integer(1), seq(issuer, serial), seq(oid(SHA256), NULL),
                      b'\xA0' + attributes[1:],                             # [0] IMPLICIT authenticatedAttributes
                      seq(oid('1.2.840.113549.1.1.1'), NULL), octets(signature))
    signed_data = seq(integer(1), set_of(seq(oid(SHA256), NULL)), seq(oid(SPC_INDIRECT_DATA), ctx(0, spc)),
                      ctx(0, leaf + (folder / ROOT).read_bytes()), set_of(signer_info))
    content_info = seq(oid('1.2.840.113549.1.7.2'), ctx(0, signed_data))

    pad = (-len(content_info)) % 8
    table = struct.pack('<IHH', 8 + len(content_info) + pad, 0x0200, 0x0002) + content_info + b'\0' * pad
    offset = len(data)
    data += table
    struct.pack_into('<II', data, certdir_off, offset, len(table))
    struct.pack_into('<I', data, checksum_off, pe_checksum(data, checksum_off))
    Path(dst).write_bytes(data)
    print(f'Signed {dst}: image hash {digest.hex()[:16]}...')


def check(path, folder=None):
    """True when PATH carries one signature whose image hash matches the file (and, with
    FOLDER, which embeds FOLDER's certificate)."""
    data = Path(path).read_bytes()
    checksum_off, certdir_off = pe_fields(data)
    offset, size = struct.unpack_from('<II', data, certdir_off)
    if not size or offset + size != len(data):
        return False
    table = data[offset:]
    digest = image_hash(data, checksum_off, certdir_off, offset)
    if octets(digest) not in table:
        return False
    return folder is None or (Path(folder) / LEAF).read_bytes() in table


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('create-certificate').add_argument('folder')
    p = commands.add_parser('sign')
    p.add_argument('folder')
    p.add_argument('input')
    p.add_argument('output')
    p = commands.add_parser('check')
    p.add_argument('file')
    p.add_argument('folder', nargs='?')
    args = parser.parse_args()
    if args.command == 'create-certificate':
        create_certificate(args.folder)
    elif args.command == 'sign':
        sign(args.folder, args.input, args.output)
    else:
        ok = check(args.file, args.folder)
        print('signed' if ok else 'not signed (or the signature does not match the file)')
        sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
