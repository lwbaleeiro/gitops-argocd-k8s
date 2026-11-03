#!/usr/bin/env python3
"""
generate_payload.py

Script CLI para gerar cargas de teste e publicar na fila do RabbitMQ.
Pode ser executado localmente ou dentro de um pod no cluster.

Uso:
  python scripts/generate_payload.py --items 50 --size 128 --count 1
  python scripts/generate_payload.py --items 100 --size 256 --count 5 --interval 0.5
"""

import sys
import os

# Adiciona o diretório src/ ao sys.path para reutilizar os módulos
src_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src"))
if src_dir not in sys.path:
    sys.path.insert(0, src_dir)

from producer import main_cli if hasattr(sys.modules.get('producer', None), 'main_cli') else None

if __name__ == "__main__":
    import argparse
    import time
    from producer import send_carga

    parser = argparse.ArgumentParser(description="Gerador CLI de Cargas para RabbitMQ")
    parser.add_argument("--items", type=int, default=10, help="Quantidade de itens na carga (default: 10)")
    parser.add_argument("--size", type=int, default=64, help="Tamanho em bytes por item (default: 64)")
    parser.add_argument("--source", type=str, default="cli-script", help="Origem da carga (default: cli-script)")
    parser.add_argument("--count", type=int, default=1, help="Quantidade de cargas a enviar (default: 1)")
    parser.add_argument("--interval", type=float, default=1.0, help="Intervalo em segundos entre cargas (default: 1.0)")

    args = parser.parse_args()

    print(f"🚀 Iniciando envio de {args.count} carga(s)... ({args.items} itens cada, ~{args.size} bytes/item)")
    for n in range(args.count):
        try:
            payload = send_carga(item_count=args.items, item_size_bytes=args.size, source=args.source)
            print(f"[{n+1}/{args.count}] ✔ Carga enviada com sucesso! ID: {payload['payload_id']} ({payload['payload_size_bytes']} bytes)")
        except Exception as e:
            print(f"[{n+1}/{args.count}] ✘ Falha ao enviar carga: {e}", file=sys.stderr)
        
        if n < args.count - 1:
            time.sleep(args.interval)

