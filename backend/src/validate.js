function validateTitle(value) {
  if (typeof value !== 'string') return null;
  const title = value.trim();
  return title.length >= 1 && title.length <= 100 ? title : null;
}
module.exports = { validateTitle };
