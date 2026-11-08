import { ActionRowBuilder, ButtonBuilder, ButtonStyle, EmbedBuilder } from 'discord.js';
import type { Room, RoomStats } from './roomApi.js';

export function drift(value: number | null | undefined): string {
  return value == null ? '—' : `${Math.round(value)} ms`;
}

export function roomEmbed(room: Room, stats: RoomStats | undefined, voiceName: string): EmbedBuilder {
  return new EmbedBuilder()
    .setTitle(voiceName)
    .addFields(
      { name: 'host', value: room.host_name || room.host_id, inline: true },
      { name: 'members', value: `${room.members.length}/50`, inline: true },
      { name: 'now playing', value: room.playback?.item_ref || 'nothing yet' },
      { name: 'drift p95', value: drift(stats?.p95_drift_ms), inline: true },
    );
}

// Discord message components are shared by all viewers. Close is only displayed in
// the host's ephemeral status response, never in the public card.
export function cardButtons(roomId: string, isHost: boolean): ActionRowBuilder<ButtonBuilder> {
  const row = new ActionRowBuilder<ButtonBuilder>().addComponents(
    new ButtonBuilder().setCustomId(`room:status:${roomId}`).setLabel('Status').setStyle(ButtonStyle.Secondary),
  );
  if (isHost) row.addComponents(
    new ButtonBuilder().setCustomId(`room:close:${roomId}`).setLabel('Close').setStyle(ButtonStyle.Danger),
  );
  return row;
}

export function statusEmbed(room: Room, stats: RoomStats | undefined, voiceName: string): EmbedBuilder {
  return roomEmbed(room, stats, voiceName).addFields(
    { name: 'room id', value: room.room_id, inline: true },
    { name: 'rev', value: String(room.rev), inline: true },
    { name: 'drift p50', value: drift(stats?.p50_drift_ms), inline: true },
    { name: 'locked / controls', value: `${room.locked ? 'yes' : 'no'} / ${room.controls}`, inline: true },
  );
}
