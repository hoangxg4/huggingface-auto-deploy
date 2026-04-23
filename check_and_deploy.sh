#!/bin/bash

# 1. Tải cấu hình từ repo ngoài
echo "📥 Đang tải cấu hình..."
curl -s -H "Authorization: token $CONFIG_REPO_PAT" -L "$CONFIG_RAW_URL" -o config.json

if [ ! -f config.json ]; then
    echo "❌ Không thể tải file config.json"
    exit 1
fi

# 2. Lấy mật khẩu mã hóa từ config
PWD_STATE=$(jq -r '.state_encrypt_pass' config.json)
STATE_FILE="apps_state.json"
STATE_FILE_ENC="apps_state.json.enc"

# 3. Giải mã file state
if [ -f "$STATE_FILE_ENC" ]; then
    openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in "$STATE_FILE_ENC" -out "$STATE_FILE" -k "$PWD_STATE" 2>/dev/null
fi
[ ! -f "$STATE_FILE" ] && echo "{}" > "$STATE_FILE"

updated=false

# 4. Quét danh sách monitor
jq -c '.monitors[]' config.json | while read -r item; do
    type=$(echo "$item" | jq -r '.type')
    source=$(echo "$item" | jq -r '.source')
    target=$(echo "$item" | jq -r '.target_space')
    token_name=$(echo "$item" | jq -r '.hf_token_name')
    track_type=$(echo "$item" | jq -r '.track_type // "commit"')
    
    hf_token=${!token_name}
    current_ver=""

    echo "🔍 Checking $source..."

    if [ "$type" == "docker" ]; then
        current_ver=$(regctl image digest "$source" 2>/dev/null)
    elif [ "$type" == "git" ]; then
        if [ "$track_type" == "release" ]; then
            # Lấy tag cuối cùng từ bất kỳ nền tảng git nào
            current_ver=$(git ls-remote --tags "$source" | cut -d/ -f3 | grep -v "\^{}" | tail -n1)
        else
            branch=$(echo "$item" | jq -r '.branch // "HEAD"')
            current_ver=$(git ls-remote "$source" "$branch" | cut -f1)
        fi
    fi

    if [ -z "$current_ver" ] || [ "$current_ver" == "null" ]; then 
        echo "⚠️  Bỏ qua: Không lấy được thông tin từ $source"
        continue
    fi

    # Key kết hợp để hỗ trợ 1 nguồn cho nhiều đích
    key="${source}#${target}"
    old_ver=$(jq -r ".[\"$key\"] // empty" "$STATE_FILE")

    if [ "$current_ver" != "$old_ver" ]; then
        echo "🚀 Phát hiện mới! Trigger Space: $target"
        
        status=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST \
            -H "Authorization: Bearer $hf_token" \
            "https://huggingface.co/api/spaces/$target/restart?factory=true")

        if [ "$status" == "200" ]; then
            tmp=$(mktemp)
            jq ".[\"$key\"] = \"$current_ver\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
            updated=true
            echo "updated" > .flag
        else
            echo "❌ Lỗi API HF ($status) cho Space $target"
        fi
    fi
done

# 5. Mã hóa lại nếu có thay đổi
if [ -f .flag ]; then
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -in "$STATE_FILE" -out "$STATE_FILE_ENC" -k "$PWD_STATE"
    rm "$STATE_FILE" .flag
fi
rm config.json
