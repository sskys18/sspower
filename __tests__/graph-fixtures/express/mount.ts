// P4 limitation: mount-path expansion (`/api/v1/users` from
// `app.use('/api/v1', r)`) is deferred to P5. The extractor records
// the mount under routeMounts but does NOT synthesize prefixed route
// nodes for the imported router's routes. Test expectations therefore
// only assert the 5 directly-extracted routes (3 from app.ts, 2 from
// router.ts); recall ≥ 0.70 is satisfied without mount expansion
// (5 / 7 ≈ 0.714).
import express from 'express';
import r from './router';

const app = express();
app.use('/api/v1', r);
export default app;
