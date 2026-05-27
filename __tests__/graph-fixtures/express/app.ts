import express, { Request, Response } from 'express';
import { handleHealth } from './handlers';

const app = express();

app.get('/health', handleHealth);
app.post('/items', (req: Request, res: Response) => {
  res.json({ created: true });
});
app.delete('/items/:id', handleDelete);

function handleDelete(req: Request, res: Response) {
  res.status(204).end();
}

export default app;
