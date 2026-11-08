import { config } from 'dotenv';
import {
  ChatInputCommandInteraction, Client, Events, GatewayIntentBits, MessageFlags,
  SlashCommandBuilder,
} from 'discord.js';
import type { ButtonInteraction, GuildMember, Interaction, Message, VoiceBasedChannel } from 'discord.js';
import { fileURLToPath } from 'node:url';
import { createRoomApi, RoomApiError } from './roomApi.js';
import type { Room } from './roomApi.js';
import { cardButtons, roomEmbed, statusEmbed } from './card.js';
import { canCreate, canInvite } from './voice.js';

if (!process.env.DISCORD_TOKEN) {
  config({ path: fileURLToPath(new URL('../../deploy/discord-bot.env', import.meta.url)), quiet: true });
}

const token = process.env.DISCORD_TOKEN;
const appId = process.env.DISCORD_APP_ID;
const server = process.env.WATCH_SERVER;
const botToken = process.env.WT_BOT_TOKEN;
if (!token || !appId || !server || !botToken) throw new Error('Missing Discord bot configuration');

const api = createRoomApi(server, botToken);
const client = new Client({ intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildVoiceStates] });
const smoke = process.argv.includes('--smoke');
const command = new SlashCommandBuilder().setName('room').setDescription('Manage a watch room')
  .addSubcommand(sub => sub.setName('create').setDescription('Create a room for this voice call'))
  .addSubcommand(sub => sub.setName('invite').setDescription('Invite someone in this voice call')
    .addUserOption(option => option.setName('user').setDescription('User to invite').setRequired(true)))
  .addSubcommand(sub => sub.setName('status').setDescription('View room status'))
  .addSubcommand(sub => sub.setName('lock').setDescription('Lock the room'))
  .addSubcommand(sub => sub.setName('unlock').setDescription('Unlock the room'))
  .addSubcommand(sub => sub.setName('close').setDescription('Close the room'));

interface Binding {
  id: string;
  channel: VoiceBasedChannel;
  card: Message;
  timer?: NodeJS.Timeout;
  idleSince?: number;
}

const bindings = new Map<string, Binding>();
const creating = new Set<string>();
const key = (guildId: string, channelId: string): string => `${guildId}:${channelId}`;

async function refresh(binding: Binding): Promise<void> {
  try {
    const [room, stats] = await Promise.all([api.get(binding.id), api.stats()]);
    if (room.members.length) binding.idleSince = undefined;
    else binding.idleSince ??= Date.now();
    if (binding.idleSince && Date.now() - binding.idleSince >= 30 * 60_000) {
      if (binding.timer) clearInterval(binding.timer);
      binding.timer = undefined;
      return;
    }
    await binding.card.edit({ embeds: [roomEmbed(room, stats.rooms.find(s => s.room_id === binding.id), binding.channel.name)],
      components: [cardButtons(binding.id, false)] });
  } catch (error) {
    if (error instanceof RoomApiError && error.status === 404) {
      unbind(binding);
    } else {
      console.error('Room card refresh failed');
    }
  }
}

function unbind(binding: Binding): void {
  if (binding.timer) clearInterval(binding.timer);
  bindings.delete(key(binding.channel.guild.id, binding.channel.id));
}

function startRefresh(binding: Binding): void {
  if (!binding.timer) binding.timer = setInterval(() => { void refresh(binding); }, 10_000);
}

async function member(interaction: ChatInputCommandInteraction | ButtonInteraction, userId: string): Promise<GuildMember> {
  if (!interaction.guild) throw new Error('Use this command in a server.');
  return interaction.guild.members.fetch(userId);
}

function currentBinding(interaction: ChatInputCommandInteraction | ButtonInteraction): Binding | undefined {
  if (!interaction.guildId) return undefined;
  return bindings.get(key(interaction.guildId, interaction.channelId));
}

async function showStatus(interaction: ChatInputCommandInteraction | ButtonInteraction, binding: Binding): Promise<void> {
  const [room, stats] = await Promise.all([api.get(binding.id), api.stats()]);
  startRefresh(binding);
  await interaction.reply({ flags: MessageFlags.Ephemeral,
    embeds: [statusEmbed(room, stats.rooms.find(s => s.room_id === binding.id), binding.channel.name)],
    components: [cardButtons(binding.id, interaction.user.id === room.host_id)] });
}

async function closeRoom(interaction: ChatInputCommandInteraction | ButtonInteraction, binding: Binding, room: Room): Promise<void> {
  if (room.host_id !== interaction.user.id) {
    await interaction.reply({ content: 'Only the host can close this room.', flags: MessageFlags.Ephemeral });
    return;
  }
  await api.delete(binding.id);
  unbind(binding);
  await binding.card.delete().catch(() => {});
  await interaction.reply({ content: 'Room closed.', flags: MessageFlags.Ephemeral });
}

async function handleCommand(interaction: ChatInputCommandInteraction): Promise<void> {
  if (!interaction.guild || !interaction.inGuild()) {
    await interaction.reply({ content: 'Use this command in a server voice chat.', flags: MessageFlags.Ephemeral });
    return;
  }
  const sub = interaction.options.getSubcommand();
  const binding = currentBinding(interaction);
  if (sub === 'create') {
    const channel = interaction.guild.channels.cache.get(interaction.channelId);
    if (!channel?.isVoiceBased()) {
      await interaction.reply({ content: 'Use the text chat attached to your voice channel.', flags: MessageFlags.Ephemeral });
      return;
    }
    const caller = await member(interaction, interaction.user.id);
    const reason = canCreate(caller, channel);
    if (reason) {
      await interaction.reply({ content: reason, flags: MessageFlags.Ephemeral });
      return;
    }
    const channelKey = key(interaction.guildId, channel.id);
    if (bindings.has(channelKey) || creating.has(channelKey)) {
      await interaction.reply({ content: 'This voice channel already has a room.', flags: MessageFlags.Ephemeral });
      return;
    }
    creating.add(channelKey);
    try {
      await interaction.deferReply({ flags: MessageFlags.Ephemeral });
      const created = await api.create({ host_id: interaction.user.id, host_name: caller.displayName,
        guild_id: interaction.guildId, voice_channel_id: channel.id });
      const room = await api.get(created.room_id);
      try {
        const card = await interaction.channel?.send({ embeds: [roomEmbed(room, undefined, channel.name)],
          components: [cardButtons(created.room_id, false)] });
        if (!card) throw new Error('Cannot post a card here.');
        const next: Binding = { id: created.room_id, channel, card };
        bindings.set(channelKey, next);
        startRefresh(next);
        await interaction.editReply(`Room created: ${created.room_id}`);
      } catch (error) {
        await api.delete(created.room_id).catch(() => {});
        throw error;
      }
    } finally {
      creating.delete(channelKey);
    }
    return;
  }
  if (!binding) {
    await interaction.reply({ content: 'No room is bound to this voice channel.', flags: MessageFlags.Ephemeral });
    return;
  }
  if (sub === 'status') {
    await showStatus(interaction, binding);
    return;
  }
  const room = await api.get(binding.id);
  if (sub === 'invite') {
    const target = interaction.options.getUser('user', true);
    const [caller, invitee] = await Promise.all([member(interaction, interaction.user.id), member(interaction, target.id)]);
    const reason = canInvite(caller, invitee, binding.channel);
    if (reason) {
      await interaction.reply({ content: reason, flags: MessageFlags.Ephemeral });
      return;
    }
    if (room.members.some(m => m.user_id === target.id)) {
      await interaction.reply({ content: 'That user is already in the room.', flags: MessageFlags.Ephemeral });
      return;
    }
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    const minted = await api.token(binding.id, { user_id: target.id, user_name: invitee.displayName });
    const text = `Room: ${binding.id}\nToken: ${minted.join_token}\nOpen the app, paste both, or run:\nwt-play --server ${server} --room ${binding.id} --token ${minted.join_token} --file <path>`;
    try {
      await target.send(text);
      await interaction.editReply('Invite sent by DM.');
    } catch {
      await interaction.editReply(text);
    }
  } else if (sub === 'close') {
    await closeRoom(interaction, binding, room);
  } else if (sub === 'lock' || sub === 'unlock') {
    if (room.host_id !== interaction.user.id) {
      await interaction.reply({ content: 'Only the host can change the lock.', flags: MessageFlags.Ephemeral });
      return;
    }
    await api.patch(binding.id, { locked: sub === 'lock' });
    await interaction.reply({ content: `Room ${sub === 'lock' ? 'locked' : 'unlocked'}.`, flags: MessageFlags.Ephemeral });
    void refresh(binding);
  }
}

async function handleInteraction(interaction: Interaction): Promise<void> {
  if (interaction.isChatInputCommand() && interaction.commandName === 'room') {
    await handleCommand(interaction);
  } else if (interaction.isButton() && interaction.customId.startsWith('room:')) {
    const binding = currentBinding(interaction);
    const [prefix, action, roomId] = interaction.customId.split(':');
    if (prefix !== 'room' || !binding || binding.id !== roomId) {
      await interaction.reply({ content: 'This room is no longer active here.', flags: MessageFlags.Ephemeral });
    } else if (action === 'status') {
      await showStatus(interaction, binding);
    } else if (action === 'close') {
      await closeRoom(interaction, binding, await api.get(binding.id));
    }
  }
}

client.on(Events.InteractionCreate, interaction => {
  void handleInteraction(interaction).catch(async error => {
    const message = error instanceof RoomApiError ? `Room server: ${error.code} (HTTP ${error.status})` : 'Could not complete this request.';
    console.error('Room interaction failed');
    if (!interaction.isRepliable()) return;
    try {
      if (interaction.deferred || interaction.replied) await interaction.editReply({ content: message });
      else await interaction.reply({ content: message, flags: MessageFlags.Ephemeral });
    } catch { /* interaction expired */ }
  });
});

if (smoke) {
  const timeout = setTimeout(() => {
    console.error('Smoke connection timed out');
    client.destroy();
    process.exitCode = 1;
  }, 19_000);
  client.once(Events.ClientReady, ready => {
    clearTimeout(timeout);
    console.log(`SMOKE_OK guilds=${ready.guilds.cache.size}`);
    ready.destroy();
  });
} else {
  client.on(Events.ClientReady, ready => {
    console.log(`logged in as ${ready.user.tag}, guilds=${ready.guilds.cache.size}`);
    for (const guild of ready.guilds.cache.values()) {
      void guild.commands.set([command.toJSON()]).catch(() => console.error('Command registration failed'));
    }
  });
  client.on(Events.GuildCreate, guild => {
    void guild.commands.set([command.toJSON()]).catch(() => console.error('Command registration failed'));
  });
}

client.login(token).catch(() => {
  console.error('Discord login failed');
  process.exitCode = 1;
});
