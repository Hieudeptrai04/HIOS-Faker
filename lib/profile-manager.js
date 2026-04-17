/**
 * ChangeInfoIos - Profile Manager
 * Save/Load/Import/Export device parameter profiles
 */

const fs = require('fs');
const path = require('path');

const PROFILES_DIR = path.join(__dirname, '..', 'profiles');

class ProfileManager {
  constructor() {
    // Ensure profiles directory exists
    if (!fs.existsSync(PROFILES_DIR)) {
      fs.mkdirSync(PROFILES_DIR, { recursive: true });
    }
  }

  /**
   * Save profile
   */
  save(name, profile) {
    const filename = this._sanitizeName(name) + '.json';
    const filepath = path.join(PROFILES_DIR, filename);
    
    const data = {
      name,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      profile,
    };

    fs.writeFileSync(filepath, JSON.stringify(data, null, 2), 'utf-8');
    return { success: true, filename, path: filepath };
  }

  /**
   * Load profile by name
   */
  load(name) {
    const filename = this._sanitizeName(name) + '.json';
    const filepath = path.join(PROFILES_DIR, filename);

    if (!fs.existsSync(filepath)) {
      throw new Error(`Profile "${name}" not found`);
    }

    const data = JSON.parse(fs.readFileSync(filepath, 'utf-8'));
    return data;
  }

  /**
   * List all profiles
   */
  list() {
    const files = fs.readdirSync(PROFILES_DIR).filter(f => f.endsWith('.json'));
    return files.map(f => {
      try {
        const data = JSON.parse(fs.readFileSync(path.join(PROFILES_DIR, f), 'utf-8'));
        return {
          filename: f,
          name: data.name,
          productType: data.profile?._productType || 'Unknown',
          marketing: data.profile?.MarketingName || 'Unknown',
          iosVersion: data.profile?.systemVersion || 'Unknown',
          createdAt: data.createdAt,
          updatedAt: data.updatedAt,
        };
      } catch (e) {
        return { filename: f, name: f, error: e.message };
      }
    });
  }

  /**
   * Delete profile
   */
  delete(name) {
    const filename = this._sanitizeName(name) + '.json';
    const filepath = path.join(PROFILES_DIR, filename);

    if (!fs.existsSync(filepath)) {
      throw new Error(`Profile "${name}" not found`);
    }

    fs.unlinkSync(filepath);
    return { success: true };
  }

  /**
   * Duplicate profile
   */
  duplicate(name, newName) {
    const data = this.load(name);
    data.name = newName;
    data.createdAt = new Date().toISOString();
    data.updatedAt = new Date().toISOString();
    return this.save(newName, data.profile);
  }

  /**
   * Export profile to JSON string (for download)
   */
  exportProfile(name) {
    const data = this.load(name);
    return JSON.stringify(data, null, 2);
  }

  /**
   * Import profile from JSON string
   */
  importProfile(jsonString, overrideName) {
    const data = JSON.parse(jsonString);
    const name = overrideName || data.name || `imported_${Date.now()}`;
    return this.save(name, data.profile || data);
  }

  /**
   * Get profiles directory path
   */
  getProfilesDir() {
    return PROFILES_DIR;
  }

  _sanitizeName(name) {
    return name.replace(/[^a-zA-Z0-9_-]/g, '_').substring(0, 64);
  }
}

module.exports = ProfileManager;
