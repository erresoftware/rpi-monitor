'use strict';

const crypto = require('node:crypto');

function timingSafeEqual(a, b) {
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  if (bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

function tokenAuth(expectedToken) {
  if (!expectedToken) {
    throw new Error('AUTH_TOKEN must be configured');
  }
  return (req, res, next) => {
    const header = req.get('authorization') || '';
    const [scheme, value] = header.split(' ');
    if (scheme !== 'Bearer' || !value || !timingSafeEqual(value, expectedToken)) {
      return res.status(401).json({ error: 'Unauthorized' });
    }
    return next();
  };
}

module.exports = { tokenAuth };
