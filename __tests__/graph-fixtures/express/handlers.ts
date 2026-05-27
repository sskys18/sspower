import { Request, Response } from 'express';

export function handleHealth(req: Request, res: Response) {
  res.json({ ok: true });
}

export function listUsers(req: Request, res: Response) {
  res.json({ users: [] });
}

export function createUser(req: Request, res: Response) {
  res.status(201).json({ id: 'new' });
}
