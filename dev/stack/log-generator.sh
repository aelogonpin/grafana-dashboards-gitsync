#!/bin/sh
# Simula los logs de una tienda online por cliente y los envía a Loki, cada uno a su tenant.
# Formato logfmt: level=... msg="..." pedido=... importe=... metodo=... canal=... region=...
#                 endpoint=... status=... duration_ms=... sku=...
# Eventos: pedido creado (~60 %), carrito abandonado, pago rechazado (error),
#          latencia alta y stock bajo (warn). Cada cliente tiene un volumen distinto.
set -eu
CLIENTES="${CLIENTES:-cliente-a:1 cliente-b:2 cliente-c:3}"   # cliente:eventos por ciclo

pick() { shift $((RANDOM % $# )); echo "$1"; }

i=0
while true; do
  for entry in $CLIENTES; do
    c="${entry%%:*}"; n="${entry##*:}"
    values=""
    k=0
    while [ "$k" -lt "$n" ]; do
      k=$((k + 1)); i=$((i + 1))
      canal=$(pick web web web app app tienda)
      region=$(pick norte sur este oeste centro)
      metodo=$(pick tarjeta tarjeta tarjeta bizum paypal transferencia)
      importe="$((5 + RANDOM % 240)).$((RANDOM % 90 + 10))"
      dur=$((40 + RANDOM % 260))
      r=$((RANDOM % 100))
      if   [ "$r" -lt 60 ]; then level=info;  line="msg=\"pedido creado\" pedido=$i importe=$importe metodo=$metodo canal=$canal region=$region endpoint=/checkout status=201 duration_ms=$dur"
      elif [ "$r" -lt 75 ]; then level=info;  line="msg=\"carrito abandonado\" importe=$importe canal=$canal region=$region endpoint=/cart status=200 duration_ms=$((dur / 2))"
      elif [ "$r" -lt 83 ]; then level=error; line="msg=\"pago rechazado\" pedido=$i importe=$importe metodo=$metodo canal=$canal region=$region endpoint=/checkout status=402 duration_ms=$dur motivo=$(pick fondos_insuficientes tarjeta_caducada fraude timeout_pasarela)"
      elif [ "$r" -lt 93 ]; then level=warn;  line="msg=\"latencia alta\" endpoint=$(pick /checkout /search /cart) canal=$canal region=$region status=200 duration_ms=$((800 + RANDOM % 2200))"
      else                       level=warn;  line="msg=\"stock bajo\" sku=SKU-$((1000 + RANDOM % 40)) unidades=$((RANDOM % 5)) region=$region"
      fi
      ts="$(date +%s)$(printf '%03d' "$k")000000"
      line=$(echo "level=$level $line cliente=$c" | sed 's/"/\\"/g')   # comillas escapadas para el JSON
      values="$values{\"stream\":{\"app\":\"tienda\",\"cliente\":\"$c\",\"level\":\"$level\"},\"values\":[[\"$ts\",\"$line\"]]},"
    done
    curl -s -o /dev/null -H "Content-Type: application/json" -H "X-Scope-OrgID: $c" \
      -X POST "$LOKI_URL/loki/api/v1/push" -d "{\"streams\":[${values%,}]}"
  done
  sleep 2
done
