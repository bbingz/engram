// src/core/project.ts
import { execFile } from 'node:child_process';
import { basename } from 'node:path';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

// 尝试从 git remote 获取项目名，fallback 到目录名
export async function resolveProjectName(cwd: string): Promise<string> {
  if (!cwd) return '';

  try {
    const { stdout } = await execFileAsync(
      'git',
      ['-C', cwd, 'remote', 'get-url', 'origin'],
      {
        timeout: 2000,
      },
    );
    const url = stdout.trim();
    // 从 git URL 提取仓库名
    // https://github.com/user/repo.git → repo
    // git@github.com:user/repo.git → repo
    const match = url.match(/([^/:]+?)(?:\.git)?$/);
    if (match?.[1]) return match[1];
  } catch {
    // 不是 git 仓库或命令失败，fallback 到目录名
  }

  // 去除末尾 /，取最后一段
  const cleanCwd = cwd.replace(/\/$/, '');
  return basename(cleanCwd) || cwd;
}
