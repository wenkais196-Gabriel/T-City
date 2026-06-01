import os
import sys
from PIL import Image

# Setup search paths for the folder
possible_paths = [
    os.path.expanduser("~/Desktop/hospital_textures"),
    os.path.expanduser("~/Documents/hospital_textures"),
    os.path.expanduser("~/OneDrive/Desktop/hospital_textures"),  # Common on Windows with OneDrive
    "C:/Users/swkgb/Desktop/hospital_textures",
    "./hospital_textures"
]

target_dir = None
for path in possible_paths:
    if os.path.exists(path) and os.path.isdir(path):
        target_dir = path
        break

if not target_dir:
    print("❌ 未能自动找到 'hospital_textures' 文件夹。")
    print("请确认您将该文件夹保存在了桌面或文档，或者手动在下方输入文件夹的绝对路径：")
    user_input = input("请输入 hospital_textures 文件夹路径: ").strip()
    if os.path.exists(user_input) and os.path.isdir(user_input):
        target_dir = user_input
    else:
        print("❌ 路径不存在，退出程序。")
        sys.exit(1)

print(f"🔍 成功定位贴图文件夹: {target_dir}")
print("⚡ 开始批量自适应压制贴图...")

optimized_count = 0
skipped_count = 0

# Allowed maximum resolution for high-performance optimization
MAX_RESOLUTION = 1024

for filename in os.listdir(target_dir):
    if filename.lower().endswith(('.png', '.jpg', '.jpeg')):
        file_path = os.path.join(target_dir, filename)
        try:
            with Image.open(file_path) as img:
                width, height = img.size
                
                # Check if resizing is necessary
                if width > MAX_RESOLUTION or height > MAX_RESOLUTION:
                    # Calculate new size maintaining aspect ratio
                    if width >= height:
                        new_width = MAX_RESOLUTION
                        new_height = int((height * MAX_RESOLUTION) / width)
                    else:
                        new_height = MAX_RESOLUTION
                        new_width = int((width * MAX_RESOLUTION) / height)
                        
                    # Ensure dimensions are even numbers (better for GPU compression)
                    if new_width % 2 != 0: new_width -= 1
                    if new_height % 2 != 0: new_height -= 1
                    
                    resized_img = img.resize((new_width, new_height), Image.Resampling.LANCZOS)
                    resized_img.save(file_path)
                    print(f"✅ 已优化: {filename} ({width}x{height} -> {new_width}x{new_height})")
                    optimized_count += 1
                else:
                    # Optional: Re-save to optimize PNG compression level if needed
                    # We can skip smaller files to avoid unnecessary processing
                    skipped_count += 1
        except Exception as e:
            print(f"⚠️ 处理文件失败 {filename}: {e}")

print("\n🎉 资产优化自检完毕！")
print(f"📊 统计报告: 压缩大体积贴图: {optimized_count} 张，保留轻量级贴图: {skipped_count} 张。")
