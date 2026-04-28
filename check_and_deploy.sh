#!/bin/bash
set +x

# 1. Tải cấu hình
curl -s -H "Authorization: token $CONFIG_REPO_PAT" -L "$CONFIG_RAW_URL" -o config.json

# KIỂM TRA HỢP LỆ JSON TRƯỚC KHI CHẠY
if ! jq '.' config.json > /dev/null 2>&1; then
    echo "❌ Lỗi: File config.json không đúng định dạng JSON (sai cú pháp)."
    exit 1
fi

PWD_STATE=$(jq -r '.state_encrypt_pass // empty' config.json)
[ -n "$PWD_STATE" ] && echo "::add-mask::$PWD_STATE"

STATE_FILE="apps_state.json"
STATE_FILE_ENC="apps_state.json.enc"

if [ -f "$STATE_FILE_ENC" ] && [ -n "$PWD_STATE" ]; then
    openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in "$STATE_FILE_ENC" -out "$STATE_FILE" -k "$PWD_STATE" 2>/dev/null
fi
[ ! -f "$STATE_FILE" ] && echo "{}" > "$STATE_FILE"

# 3. Duyệt danh sách
# Thêm kiểm tra hf_token rỗng để tránh lỗi Warning mask
jq -c '.monitors[]' config.json | while read -r item; do
    source=$(echo "$item" | jq -r '.source // empty')
    target=$(echo "$item" | jq -r '.target_space // empty')
    hf_token=$(echo "$item" | jq -r '.hf_token // empty')

    # Chỉ add mask nếu giá trị không rỗng
    [ -n "$hf_token" ] && echo "::add-mask::$hf_token"
    [ -n "$source" ] && echo "::add-mask::$source"

    # ... (giữ nguyên phần logic check version và curl trigger) ...
    # Lưu ý: Nhớ dùng biến $source, $target, $hf_token đã lấy ở trên
    
    type=$(echo "$item" | jq -r '.type')
    track_type=$(echo "$item" | jq -r '.track_type // "commit"')
    current_ver=""

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
        status=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST \
            -H "Authorization: Bearer $hf_token" \
            "https://huggingface.co/api/spaces/$target/restart?factory=true")

        if [ "$status" == "200" ]; then
            tmp=$(mktemp)
            jq ".[\"$key\"] = \"$current_ver\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
            echo "1" > .update_detected
        fi
    fi
done

# 4. Mã hóa lại
if [ -f .update_detected ] && [ -n "$PWD_STATE" ]; then
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -in "$STATE_FILE" -out "$STATE_FILE_ENC" -k "$PWD_STATE"
    rm "$STATE_FILE" .update_detected
fi
rm -f config.json
echo "✅ Quá trình kiểm tra hoàn tất."
