import subprocess
import sys


def main():
    issue = sys.argv[1]
    repo = sys.argv[2]

    result = subprocess.run([
        'gh', 'run', 'list',
        '--workflow', 'deploy.yml',
        '--limit', '5',
        '--json', 'conclusion,status,displayName,createdAt,htmlUrl',
        '--jq', '.[] | "- \(.displayName)  \(.status) / \(.conclusion // "pending")  \(.htmlUrl)"',
    ], capture_output=True, text=True)

    lines = result.stdout.strip()
    if not lines:
        lines = "No recent deploys"

    body = f"## Recent Deploys\n\n{lines}"

    subprocess.run([
        'gh', 'issue', 'comment', issue,
        '--repo', repo,
        '--body', body,
    ], check=True)


if __name__ == '__main__':
    main()
