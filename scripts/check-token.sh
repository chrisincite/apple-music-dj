#!/bin/bash
# 驗證 ~/.config/apple-music-dj/media_user_token 是否可用。不會印出 token 內容。
F=~/.config/apple-music-dj/media_user_token
[ -s "$F" ] || { echo "✗ 檔案不存在或是空的：$F"; exit 1; }
MUT=$(tr -d '\n\r \t' < "$F")
HTML=$(curl -sL -A 'Mozilla/5.0' https://music.apple.com/tw/new)
JS=$(echo "$HTML" | grep -oE '/assets/index~[A-Za-z0-9]+\.js' | head -1)
DEV=$(curl -sL -A 'Mozilla/5.0' "https://music.apple.com$JS" | grep -oE 'eyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{20,}' | head -1)
[ -n "$DEV" ] || { echo "✗ 抓不到 web developer token"; exit 1; }
CODE=$(curl -s -o /tmp/amtok.json -w '%{http_code}' "https://amp-api.music.apple.com/v1/me/storefront" \
  -H "Authorization: Bearer $DEV" -H "Music-User-Token: $MUT" \
  -H "Content-Type: application/json" -H "Origin: https://music.apple.com" \
  -H "Cookie: media-user-token=$MUT")
echo "token 長度 ${#MUT} ｜ /v1/me/storefront → HTTP $CODE"
if [ "$CODE" = "200" ]; then
  echo "✓ token 有效"; python3 -c "import json;d=json.load(open('/tmp/amtok.json'));print('  storefront:',d['data'][0]['id'],d['data'][0]['attributes']['name'])"
else
  echo "✗ 無效：$(head -c 160 /tmp/amtok.json)"
  echo "  → 請重新複製 media-user-token（DevTools 裡在該列上按右鍵選「Copy value」，別用預覽的截斷值），"
  echo "     再跑：pbpaste > ~/.config/apple-music-dj/media_user_token && bash scripts/check-token.sh"
fi
