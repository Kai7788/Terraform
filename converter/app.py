import os
import subprocess
import re
import glob
from flask import Flask, request, send_file, after_this_request, jsonify

app = Flask(__name__)
UPLOAD_FOLDER = '/tmp'
os.makedirs(UPLOAD_FOLDER, exist_ok=True)

def sanitize_filename(name):
    """Remove invalid characters from filename"""
    return re.sub(r'[^\w\-_\. ]', '', name).strip()

@app.route('/convert', methods=['POST'])
def convert():
    url = request.form.get('url')
    format_type = request.form.get('format', 'mp3').lower()

    if not url or not ('youtube.com/' in url or 'youtu.be/' in url):
        return jsonify({"error": "Invalid YouTube URL"}), 400

    try:
        # Get sanitized video title
        result = subprocess.run([
            'yt-dlp',
            '--print', '%(title)s',
            '--skip-download',
            url
        ], capture_output=True, text=True, timeout=30)

        if result.returncode != 0:
            return jsonify({"error": f"Failed to get video info: {result.stderr}"}), 500

        title = sanitize_filename(result.stdout.strip())
        output_template = os.path.join(UPLOAD_FOLDER, title + '.%(ext)s')

        # Build yt-dlp command based on format
        if format_type == 'mp3':
            cmd = [
                'yt-dlp',
                '-x',
                '--audio-format', 'mp3',
                '--audio-quality', '0',
                '--output', output_template,
                url
            ]
        elif format_type == 'mp4':
            cmd = [
                'yt-dlp',
                '-f', 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best',
                '--merge-output-format', 'mp4',
                '--output', output_template,
                url
            ]
        else:
            return jsonify({"error": "Unsupported format. Use 'mp3' or 'mp4'."}), 400

        # Run yt-dlp
        result = subprocess.run(cmd, capture_output=True, timeout=600)
        if result.returncode != 0:
            return jsonify({"error": f"Download failed: {result.stderr}"}), 500

        # Find the actual file
        downloaded_files = glob.glob(os.path.join(UPLOAD_FOLDER, title + '.*'))
        if not downloaded_files:
            return jsonify({"error": "Downloaded file not found."}), 500

        filepath = downloaded_files[0]
        filename = os.path.basename(filepath)

        @after_this_request
        def cleanup(response):
            try:
                if os.path.exists(filepath):
                    os.remove(filepath)
            except Exception as e:
                app.logger.error(f"Cleanup failed for {filepath}: {e}")
            return response

        return send_file(filepath, as_attachment=True, download_name=filename)

    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
