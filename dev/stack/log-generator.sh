#!/bin/sh
# Genera logs de una "tienda" por cliente y los envía a Loki, cada uno a su tenant.
set -eu
CLIENTES="${CLIENTES:-cliente-a cliente-b cliente-c}"
i=0
while true; do
  for c in $CLIENTES; do
    i=$((i + 1))
    case $((i % 10)) in
      0) level=error; msg="pago rechazado pedido=$i cliente=$c" ;;
      1|2) level=warn; msg="latencia alta en /checkout ms=$((300 + i % 700)) cliente=$c" ;;
      *) level=info; msg="pedido creado pedido=$i importe=$((i % 200)).99 cliente=$c" ;;
    esac
    ts="$(date +%s)000000000"
    curl -s -o /dev/null -H "Content-Type: application/json" -H "X-Scope-OrgID: $c" \
      -X POST "$LOKI_URL/loki/api/v1/push" \
      -d "{\"streams\":[{\"stream\":{\"app\":\"tienda\",\"cliente\":\"$c\",\"level\":\"$level\"},\"values\":[[\"$ts\",\"level=$level $msg\"]]}]}"
  done
  sleep 2
done
