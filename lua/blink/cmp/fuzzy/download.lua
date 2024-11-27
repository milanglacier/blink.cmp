local download_config = require('blink.cmp.config').fuzzy.prebuilt_binaries

local download = {}

download.system_triples = {
  mac = {
    arm = 'aarch64-apple-darwin',
    x64 = 'x86_64-apple-darwin',
  },
  windows = {
    x64 = 'x86_64-pc-windows-msvc',
  },
  linux = {
    android = 'aarch64-linux-android',
    arm = function(libc) return 'aarch64-unknown-linux-' .. libc end,
    x64 = function(libc) return 'x86_64-unknown-linux-' .. libc end,
  },
}

--- @return string
function download.get_lib_extension()
  if jit.os:lower() == 'mac' or jit.os:lower() == 'osx' then return '.dylib' end
  if jit.os:lower() == 'windows' then return '.dll' end
  return '.so'
end

local root_dir = debug.getinfo(1).source:match('@?(.*/)')
download.lib_path = root_dir .. '../../../../target/release/libblink_cmp_fuzzy' .. download.get_lib_extension()
local version_path = root_dir .. '../../../../target/release/version.txt'

--- @param callback fun(err: string | nil)
function download.ensure_downloaded(callback)
  callback = vim.schedule_wrap(callback)

  if not download_config.download then return callback() end

  download.get_git_tag(function(git_version_err, git_version)
    if git_version_err then return callback(git_version_err) end

    download.get_downloaded_version(function(version_err, version)
      download.is_downloaded(function(downloaded)
        local target_version = download_config.force_version or git_version

        -- not built locally, not a git tag, error
        if not downloaded and not target_version then
          return callback(
            "Can't download from github due to not being on a git tag and no fuzzy.prebuilt_binaries.force_version set, but found no built version of the library. "
              .. 'Either run `cargo build --release` via your package manager, switch to a git tag, or set `fuzzy.prebuilt_binaries.force_version` in config. '
              .. 'See the README for more info.'
          )
        end
        -- built locally, ignore
        if downloaded and (version_err or version == nil) then return callback() end
        -- already downloaded and the correct version
        if version == target_version and downloaded then return callback() end
        -- unknown state
        if not target_version then
          return callback('Unknown error while getting pre-built binary. Consider re-installing')
        end

        -- download from github and set version
        download.from_github(target_version, function(download_err)
          if download_err then return callback(download_err) end
          download.set_downloaded_version(target_version, function(set_err)
            if set_err then return callback(set_err) end
            callback()
          end)
        end)
      end)
    end)
  end)
end

--- @param cb fun(downloaded: boolean)
function download.is_downloaded(cb)
  vim.uv.fs_stat(download.lib_path, function(err)
    if not err then return cb(true) end

    -- If not found, check without 'lib' prefix
    vim.uv.fs_stat(
      string.gsub(download.lib_path, 'libblink_cmp_fuzzy', 'blink_cmp_fuzzy'),
      function(error) cb(not error) end
    )
  end)
end

--- @param cb fun(err: string | nil, tag: string | nil)
function download.get_git_tag(cb)
  -- If repo_dir is nil, no git reposiory is found, similar to `out.code == 128`
  local repo_dir = vim.fs.root(root_dir, '.git')
  if not repo_dir then return vim.schedule(function() return cb() end) end

  vim.system({
    'git',
    '--git-dir',
    vim.fs.joinpath(repo_dir, '.git'),
    '--work-tree',
    repo_dir,
    'describe',
    '--tags',
    '--exact-match',
  }, { cwd = root_dir }, function(out)
    if out.code == 128 then return cb() end
    if out.code ~= 0 then
      return cb('While getting git tag, git exited with code ' .. out.code .. ': ' .. out.stderr)
    end
    local lines = vim.split(out.stdout, '\n')
    if not lines[1] then return cb('Expected atleast 1 line of output from git describe') end
    return cb(nil, lines[1])
  end)
end

--- @param tag string
--- @param cb fun(err: string | nil)
function download.from_github(tag, cb)
  download.get_system_triple(function(system_triple)
    if not system_triple then
      return cb(
        'Your system is not supported by pre-built binaries. You must run cargo build --release via your package manager with rust nightly. See the README for more info.'
      )
    end

    local url = 'https://github.com/saghen/blink.cmp/releases/download/'
      .. tag
      .. '/'
      .. system_triple
      .. download.get_lib_extension()

    vim.system({ 'curl', '--create-dirs', '-fLo', download.lib_path, url }, {}, function(out)
      if out.code ~= 0 then return cb('Failed to download pre-build binaries: ' .. out.stderr) end
      cb()
    end)
  end)
end

--- @param cb fun(err: string | nil, last_version: string | nil)
function download.get_downloaded_version(cb)
  return vim.uv.fs_open(version_path, 'r', 438, function(open_err, fd)
    if open_err or fd == nil then return cb(open_err or 'Unknown error') end
    vim.uv.fs_read(fd, 8, 0, function(read_err, data)
      vim.uv.fs_close(fd, function() end)
      if read_err or data == nil then return cb(read_err or 'Unknown error') end
      return cb(nil, data)
    end)
  end)
end

--- @param version string
--- @param cb fun(err: string | nil)
function download.set_downloaded_version(version, cb)
  return vim.uv.fs_open(version_path, 'w', 438, function(open_err, fd)
    if open_err or fd == nil then return cb(open_err or 'Unknown error') end
    vim.uv.fs_write(fd, version, 0, function(write_err)
      vim.uv.fs_close(fd, function() end)
      if write_err then return cb(write_err) end
      return cb()
    end)
  end)
end

--- @return string, string
function download.get_system_info()
  local os = jit.os:lower()
  if os == 'osx' then os = 'mac' end
  local arch = jit.arch:lower():match('arm') and 'arm' or jit.arch:lower():match('x64') and 'x64' or nil
  return os, arch
end

--- @param cb fun(triple: string | function | nil)
function download.get_system_triple(cb)
  if download_config.force_system_triple then return cb(download_config.force_system_triple) end

  local os, arch = download.get_system_info()
  local triples = download.system_triples[os]

  if os == 'linux' then
    if vim.fn.has('android') == 1 then return cb(triples.android) end

    vim.uv.fs_stat('/etc/alpine-release', function(err, is_alpine)
      local libc = (not err and is_alpine) and 'musl' or 'gnu'
      local triple = triples[arch]
      return cb(triple and type(triple) == 'function' and triple(libc) or triple)
    end)
  else
    return cb(triples[arch])
  end
end

function download.get_system_triple_sync()
  if download_config.force_system_triple then return download_config.force_system_triple end

  local os, arch = download.get_system_info()
  local triples = download.system_triples[os]

  if os == 'linux' then
    if vim.fn.has('android') == 1 then return triples.android end

    local success, is_alpine = pcall(vim.uv.fs_stat, '/etc/alpine-release')
    local libc = (success and is_alpine) and 'musl' or 'gnu'
    local triple = triples[arch]
    return triple and type(triple) == 'function' and triple(libc) or triple
  else
    return triples[arch]
  end
end

return download
