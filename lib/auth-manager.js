/**
 * ChangeInfoIos - Auth Manager
 * Admin-based authentication system
 * Admin creates accounts, users login to use the tool
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const USERS_FILE = path.join(__dirname, '..', 'data', 'users.json');
const SESSIONS_FILE = path.join(__dirname, '..', 'data', 'sessions.json');

class AuthManager {
  constructor() {
    // Ensure data directory
    const dataDir = path.dirname(USERS_FILE);
    if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });

    // Init users file with default admin
    if (!fs.existsSync(USERS_FILE)) {
      const defaultUsers = [
        {
          id: this._genId(),
          username: 'admin',
          password: this._hash('admin123'),
          role: 'admin',
          maxDevices: 999,
          expiresAt: null, // never expires
          createdAt: new Date().toISOString(),
          active: true,
          note: 'Default admin account',
        }
      ];
      this._saveUsers(defaultUsers);
    }

    // Init sessions
    if (!fs.existsSync(SESSIONS_FILE)) {
      fs.writeFileSync(SESSIONS_FILE, '{}', 'utf-8');
    }
  }

  // === Auth ===
  login(username, password) {
    const users = this._loadUsers();
    const user = users.find(u => u.username === username && u.active);

    if (!user) return { success: false, error: 'Tài khoản không tồn tại hoặc bị khóa' };
    if (user.password !== this._hash(password)) return { success: false, error: 'Sai mật khẩu' };

    // Check expiry
    if (user.expiresAt && new Date(user.expiresAt) < new Date()) {
      return { success: false, error: 'Tài khoản đã hết hạn' };
    }

    // Create session token
    const token = this._genToken();
    const sessions = this._loadSessions();
    sessions[token] = {
      userId: user.id,
      username: user.username,
      role: user.role,
      loginAt: new Date().toISOString(),
    };
    this._saveSessions(sessions);

    return {
      success: true,
      token,
      user: {
        id: user.id,
        username: user.username,
        role: user.role,
        maxDevices: user.maxDevices,
        expiresAt: user.expiresAt,
      }
    };
  }

  logout(token) {
    const sessions = this._loadSessions();
    delete sessions[token];
    this._saveSessions(sessions);
    return { success: true };
  }

  validateToken(token) {
    if (!token) return null;
    const sessions = this._loadSessions();
    const session = sessions[token];
    if (!session) return null;

    // Re-check user is still active & not expired
    const users = this._loadUsers();
    const user = users.find(u => u.id === session.userId);
    if (!user || !user.active) return null;
    if (user.expiresAt && new Date(user.expiresAt) < new Date()) return null;

    return session;
  }

  // === Admin: User Management ===
  createUser(adminToken, { username, password, role = 'user', maxDevices = 5, expiresAt = null, note = '' }) {
    const admin = this.validateToken(adminToken);
    if (!admin || admin.role !== 'admin') return { success: false, error: 'Không có quyền admin' };

    const users = this._loadUsers();
    if (users.find(u => u.username === username)) {
      return { success: false, error: 'Username đã tồn tại' };
    }

    const newUser = {
      id: this._genId(),
      username,
      password: this._hash(password),
      role,
      maxDevices,
      expiresAt: expiresAt || null,
      createdAt: new Date().toISOString(),
      active: true,
      note,
    };

    users.push(newUser);
    this._saveUsers(users);

    return { success: true, user: { ...newUser, password: undefined } };
  }

  listUsers(adminToken) {
    const admin = this.validateToken(adminToken);
    if (!admin || admin.role !== 'admin') return { success: false, error: 'Không có quyền admin' };

    const users = this._loadUsers();
    return users.map(u => ({
      id: u.id,
      username: u.username,
      role: u.role,
      maxDevices: u.maxDevices,
      expiresAt: u.expiresAt,
      createdAt: u.createdAt,
      active: u.active,
      note: u.note,
    }));
  }

  updateUser(adminToken, userId, updates) {
    const admin = this.validateToken(adminToken);
    if (!admin || admin.role !== 'admin') return { success: false, error: 'Không có quyền admin' };

    const users = this._loadUsers();
    const idx = users.findIndex(u => u.id === userId);
    if (idx === -1) return { success: false, error: 'User không tồn tại' };

    if (updates.password) updates.password = this._hash(updates.password);
    Object.assign(users[idx], updates);
    this._saveUsers(users);

    return { success: true };
  }

  deleteUser(adminToken, userId) {
    const admin = this.validateToken(adminToken);
    if (!admin || admin.role !== 'admin') return { success: false, error: 'Không có quyền admin' };

    let users = this._loadUsers();
    const user = users.find(u => u.id === userId);
    if (!user) return { success: false, error: 'User không tồn tại' };
    if (user.role === 'admin' && user.username === 'admin') {
      return { success: false, error: 'Không thể xóa tài khoản admin mặc định' };
    }

    users = users.filter(u => u.id !== userId);
    this._saveUsers(users);

    // Remove sessions
    const sessions = this._loadSessions();
    for (const [token, sess] of Object.entries(sessions)) {
      if (sess.userId === userId) delete sessions[token];
    }
    this._saveSessions(sessions);

    return { success: true };
  }

  changePassword(token, oldPassword, newPassword) {
    const session = this.validateToken(token);
    if (!session) return { success: false, error: 'Chưa đăng nhập' };

    const users = this._loadUsers();
    const user = users.find(u => u.id === session.userId);
    if (!user) return { success: false, error: 'User không tồn tại' };
    if (user.password !== this._hash(oldPassword)) return { success: false, error: 'Sai mật khẩu cũ' };

    user.password = this._hash(newPassword);
    this._saveUsers(users);
    return { success: true };
  }

  // === License Key System (Offline Validation) ===
  // Key format: CIXX-XXXX-XXXX-XXXX (16 chars + dashes, with embedded checksum)
  // The key can be validated offline on the mobile app using the same algorithm
  static LICENSE_SECRET = 'ci2025xk';

  generateLicenseKey(adminToken, { note = '', expiresAt = null } = {}) {
    const admin = this.validateToken(adminToken);
    if (!admin || admin.role !== 'admin') return { success: false, error: 'Không có quyền admin' };

    // Generate random payload (12 hex chars)
    const payload = crypto.randomBytes(6).toString('hex').toUpperCase();
    
    // Create checksum from payload + secret (4 hex chars)
    const checkRaw = crypto.createHash('md5')
      .update(payload + AuthManager.LICENSE_SECRET)
      .digest('hex')
      .substring(0, 4)
      .toUpperCase();

    // Format: CI + first 2 of check + dash + 4 payload + dash + 4 payload + dash + 4 payload + last 2 check
    const key = `CI${checkRaw.substring(0,2)}-${payload.substring(0,4)}-${payload.substring(4,8)}-${payload.substring(8,12)}${checkRaw.substring(2,4)}`;

    // Save to license store
    const licenses = this._loadLicenses();
    licenses.push({
      key,
      createdAt: new Date().toISOString(),
      expiresAt: expiresAt || null,
      active: true,
      note,
      usedBy: null,
    });
    this._saveLicenses(licenses);

    return { success: true, key };
  }

  listLicenses(adminToken) {
    const admin = this.validateToken(adminToken);
    if (!admin || admin.role !== 'admin') return { success: false, error: 'Không có quyền admin' };
    return { success: true, licenses: this._loadLicenses() };
  }

  revokeLicense(adminToken, key) {
    const admin = this.validateToken(adminToken);
    if (!admin || admin.role !== 'admin') return { success: false, error: 'Không có quyền admin' };
    const licenses = this._loadLicenses();
    const lic = licenses.find(l => l.key === key);
    if (!lic) return { success: false, error: 'Key không tồn tại' };
    lic.active = false;
    this._saveLicenses(licenses);
    return { success: true };
  }

  // Static method — this is the algorithm the mobile app uses to validate offline
  // Replicated in JavaScript in the mobile HTML
  static validateKeyOffline(key) {
    // Key format: CIXX-XXXX-XXXX-XXXXXX
    const clean = key.replace(/-/g, '').toUpperCase();
    if (clean.length !== 18 || !clean.startsWith('CI')) return false;
    
    const check1 = clean.substring(2, 4);  // first 2 chars of checksum
    const payload = clean.substring(4, 16); // 12 chars payload
    const check2 = clean.substring(16, 18); // last 2 chars of checksum
    
    // We can't use crypto in browser, so we use a simple hash
    // This is a simplified version — the real validation uses MD5
    // For offline, we use a simpler checksum that both Node and browser can compute
    const secret = AuthManager.LICENSE_SECRET;
    let hash = 0;
    const str = payload + secret;
    for (let i = 0; i < str.length; i++) {
      const chr = str.charCodeAt(i);
      hash = ((hash << 5) - hash) + chr;
      hash |= 0;
    }
    const expectedCheck = Math.abs(hash).toString(16).toUpperCase().padStart(4, '0').substring(0, 4);
    
    return check1 + check2 === expectedCheck.substring(0, 2) + expectedCheck.substring(2, 4);
  }

  // Generate key with the simple hash (so mobile can validate)
  generateSimpleKey(adminToken, { note = '', expiresAt = null } = {}) {
    const admin = this.validateToken(adminToken);
    if (!admin || admin.role !== 'admin') return { success: false, error: 'Không có quyền admin' };

    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    let payload = '';
    for (let i = 0; i < 12; i++) payload += chars[Math.floor(Math.random() * chars.length)];

    const secret = AuthManager.LICENSE_SECRET;
    let hash = 0;
    const str = payload + secret;
    for (let i = 0; i < str.length; i++) {
      const chr = str.charCodeAt(i);
      hash = ((hash << 5) - hash) + chr;
      hash |= 0;
    }
    const check = Math.abs(hash).toString(16).toUpperCase().padStart(4, '0').substring(0, 4);

    const key = `CI${check.substring(0,2)}-${payload.substring(0,4)}-${payload.substring(4,8)}-${payload.substring(8,12)}${check.substring(2,4)}`;

    const licenses = this._loadLicenses();
    licenses.push({
      key,
      createdAt: new Date().toISOString(),
      expiresAt: expiresAt || null,
      active: true,
      note,
      usedBy: null,
    });
    this._saveLicenses(licenses);

    return { success: true, key };
  }

  // === Internal ===
  _loadUsers() {
    try { return JSON.parse(fs.readFileSync(USERS_FILE, 'utf-8')); }
    catch { return []; }
  }

  _saveUsers(users) {
    fs.writeFileSync(USERS_FILE, JSON.stringify(users, null, 2), 'utf-8');
  }

  _loadSessions() {
    try { return JSON.parse(fs.readFileSync(SESSIONS_FILE, 'utf-8')); }
    catch { return {}; }
  }

  _saveSessions(sessions) {
    fs.writeFileSync(SESSIONS_FILE, JSON.stringify(sessions, null, 2), 'utf-8');
  }

  _loadLicenses() {
    const LICENSES_FILE = path.join(__dirname, '..', 'data', 'licenses.json');
    try { return JSON.parse(fs.readFileSync(LICENSES_FILE, 'utf-8')); }
    catch { return []; }
  }

  _saveLicenses(licenses) {
    const LICENSES_FILE = path.join(__dirname, '..', 'data', 'licenses.json');
    fs.writeFileSync(LICENSES_FILE, JSON.stringify(licenses, null, 2), 'utf-8');
  }

  _hash(str) {
    return crypto.createHash('sha256').update(str + '_changeinfoios_salt').digest('hex');
  }

  _genId() {
    return crypto.randomBytes(8).toString('hex');
  }

  _genToken() {
    return crypto.randomBytes(32).toString('hex');
  }
}

module.exports = AuthManager;

