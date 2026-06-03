#!/bin/bash
set +x

# 1. Tải cấu hình
echo "🔹 [DEBUG] Đang tải file cấu hình từ CONFIG_RAW_URL..."
curl -s -H "Authorization: token $CONFIG_REPO_PAT" -L "$CONFIG_RAW_URL" -o config.json

# KIỂM TRA HỢP LỆ JSON TRƯỚC KHI CHẠY
if ! jq '.' config.json > /dev/null 2>&1; then
    echo "❌ [ERROR] File config.json không đúng định dạng JSON (sai cú pháp)."
    exit 1
fi
echo "✅ [DEBUG] Cấu hình hợp lệ."

PWD_STATE=$(jq -r '.state_encrypt_pass // empty' config.json)
[ -n "$PWD_STATE" ] && echo "::add-mask::$PWD_STATE"

# Thu thập và mask tất cả hf_token và source trước để tránh lỗi luồng read
jq -r '.monitors[].hf_token // empty' config.json | while read -r tok; do [ -n "$tok" ] && echo "::add-mask::$tok"; done
jq -r '.monitors[].source // empty' config.json | while read -r src; do [ -n "$src" ] && echo "::add-mask::$src"; done

STATE_FILE="apps_state.json"
STATE_FILE_ENC="apps_state.json.enc"

if [ -f "$STATE_FILE_ENC" ] && [ -n "$PWD_STATE" ]; then
    echo "🔹 [DEBUG] Tìm thấy file trạng thái mã hóa. Đang tiến hành giải mã..."
    openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in "$STATE_FILE_ENC" -out "$STATE_FILE" -k "$PWD_STATE" 2>/dev/null
fi

if [ ! -f "$STATE_FILE" ]; then
    echo "🔹 [DEBUG] Không tìm thấy file trạng thái thô, khởi tạo file mới '{}'"
    echo "{}" > "$STATE_FILE"
fi

echo "📊 [DEBUG] Trạng thái hiện tại đang lưu trữ:"
cat "$STATE_FILE"
echo -e "\n--------------------------------------------------"

# 3. Duyệt danh sách
jq -c '.monitors[]' config.json | while read -r item; do
    source=$(echo "$item" | jq -r '.source // empty')
    target=$(echo "$item" | jq -r '.target_space // empty')
    hf_token=$(echo "$item" | jq -r '.hf_token // empty')
    type=$(echo "$item" | jq -r '.type')
    track_type=$(echo "$item" | jq -r '.track_type // "commit"')
    
    echo "🔍 [PROCESS] Đang kiểm tra ứng dụng: $target ($type)"

    current_ver=""
    if [ "$type" == "docker" ]; then
        echo "   [DEBUG] Loại Docker. Đang check digest từ: $source"
        current_ver=$(regctl image digest "$source" 2>/dev/null)
    elif [ "$type" == "git" ]; then
        if [ "$track_type" == "release" ]; then
            echo "   [DEBUG] Loại Git (Release). Đang check tag từ: $source"
            current_ver=$(git ls-remote --tags "$source" | cut -d/ -f3 | grep -v "\^{}" | tail -n1)
        else
            branch=$(echo "$item" | jq -r '.branch // "HEAD"')
            echo "   [DEBUG] Loại Git (Commit). Nhánh: $branch. Đang check SHA từ: $source"
            current_ver=$(git ls-remote "$source" "$branch" | cut -f1)
        fi
    fi

    echo "   [DEBUG] Phiên bản ONLINE quét được: '$current_ver'"

    if [ -z "$current_ver" ] || [ "$current_ver" == "null" ]; then 
        echo "   ⚠️ [WARN] Không lấy được phiên bản từ nguồn (Có thể lỗi mạng hoặc sai tên repo/tag). Bỏ qua..."
        continue
    fi

    key="${source}#${target}"
    old_ver=$(jq -r ".[\"$key\"] // empty" "$STATE_FILE")
    echo "   [DEBUG] Phiên bản LOCAL đang lưu:   '${old_ver:-Chưa có dữ liệu}'"

    if [ "$current_ver" != "$old_ver" ]; then
        echo "   🚀 [UPDATE DETECTED] Phát hiện có phiên bản mới! Đang gửi lệnh Trigger tới Hugging Face..."
        
        # Tạo file tạm hứng Response Body từ Hugging Face
        res_body=$(mktemp)
        
        status=$(curl -s -o "$res_body" -w "%{http_code}" \
            -X POST \
            -H "Authorization: Bearer $hf_token" \
            "https://huggingface.co/api/spaces/$target/restart?factory=true")

        echo "   [DEBUG] Hugging Face API trả về HTTP Code: $status"
        echo "   [DEBUG] Chi tiết phản hồi (Response): $(cat "$res_body")"

        if [ "$status" == "200" ]; then
            tmp=$(mktemp)
            jq ".[\"$key\"] = \"$current_ver\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
            echo "1" > .update_detected
            echo "   ✅ [SUCCESS] Đã ghi nhận update thành công cho $target vào file trạng thái."
        else
            echo "   ❌ [ERROR] Gọi API thất bại. Không cập nhật trạng thái lưu trữ."
        fi
        rm -f "$res_body"
    else
        echo "   ✅ [OK] Ứng dụng này vẫn trùng phiên bản. Không cần làm gì."
    fi
    echo "--------------------------------------------------"
done

# 4. Mã hóa lại
if [ -f .update_detected ] && [ -n "$PWD_STATE" ]; then
    echo "🔹 [DEBUG] Phát hiện có sự thay đổi phiên bản. Tiến hành mã hóa lại file trạng thái..."
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -in "$STATE_FILE" -out "$STATE_FILE_ENC" -k "$PWD_STATE"
    rm "$STATE_FILE" .update_detected
    echo "✅ [DEBUG] Đã mã hóa xong."
else
    echo "🔹 [DEBUG] Không có thay đổi nào được ghi nhận. Không cần mã hóa lại."
    rm -f "$STATE_FILE"
fi

rm -f config.json
echo "✅ Quá trình kiểm tra hoàn tất."
