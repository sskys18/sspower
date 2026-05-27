import { Router } from 'express';
import { listUsers, createUser } from './handlers';

const r = Router();
r.get('/users', listUsers);
r.post('/users', createUser);
export default r;
