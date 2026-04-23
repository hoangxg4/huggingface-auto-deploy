#!/bin/bash

# 1. Tải cấu hình từ URL bí mật
echo "📥 Đang tải cấu hình..."
curl -s -H "Authorization: token $CONFIG_REPO_PAT" -L "$CONFIG_RAW_URL" -o config.json

if [ ! -f config.json ]; then
    echo "❌ Lỗi: Không thể tải cấu hình. Kiểm tra CONFIG_RAW_URL và PAT."
    exit 1
fi

# 2. Lấy pass mã hóa và thiết lập state
PWD_STATE=$(jq -r '.state_encrypt_pass' config.json)
STATE_FILE="apps_state.json"
STATE_FILE_ENC="apps_state.json.enc"

if [ -f "$STATE_FILE_ENC" ]; then
    openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in "$STATE_FILE_ENC" -out "$STATE_FILE" -k "$PWD_STATE" 2>/dev/null
fi
[ ! -f "$STATE_FILE" ] && echo "{}" > "$STATE_FILE"

# 3. Duyệt danh sách monitors
jq -c '.monitors[]' config.json | while read -r item; do
    source=$(echo "$item" | jq -r '.source')
    target=$(echo "$item" | jq -r '.target_space')
    type=$(echo "$item" | jq -r '.type')
    track_type=$(echo "$item" | jq -r '.track_type // "commit"')
    hf_token=$(echo "$item" | jq -r '.hf_token') # Đọc trực tiếp token

    if [ -z "$hf_token" ] || [ "$hf_token" == "null" ]; then
        echo "⚠️  Bỏ qua $target: Không có token trong config."
        continue
    fi

    current_ver=""
    echo "🔍 Checking: $source"

    if [ "$type" == "docker" ]; then
        current_ver=$(regctl image digest "$source" 2>/dev/null)
    elif [ "$type" == "git" ]; then
        if [ "$track_type" == "release" ]; then
            current_ver=$(git ls-remote --tags "$source" | cut -d/ -f3 | grep -v "\^{}" | tail -n1)
        else
            branch=$(echo "$item" | jq -r '.branch // "HEAD"')
            current_ver=$(git ls-remote "$source" "$branch" | cut -f1)
        fi
    fi

    if [ -z "$current_ver" ] || [ "$current_ver" == "null" ]; then continue; fi

    key="${source}#${target}"
    old_ver=$(jq -r ".[\"$key\"] // empty" "$STATE_FILE")

    if [ "$current_ver" != "$old_ver" ]; then
        echo "🚀 Cập nhật mới ($current_ver). Trigger Space: $target"
        
        status=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST \
            -H "Authorization: Bearer $hf_token" \
            "https://huggingface.co/api/spaces/$target/restart?factory=true")

        if [ "$status" == "200" ]; then
            tmp=$(mktemp)
            jq ".[\"$key\"] = \"$current_ver\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
            echo "1" > .update_detected
        else
            echo "❌ Lỗi API HF ($status) cho Space $target"
        fi
    fi
done

# 4. Mã hóa và dọn dẹp
if [ -f .update_detected ]; then
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -in "$STATE_FILE" -out "$STATE_FILE_ENC" -k "$PWD_STATE"
    rm "$STATE_FILE" .update_detected
fi
rm config.json
