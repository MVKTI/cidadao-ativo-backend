import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      {
        global: {
          headers: { Authorization: req.headers.get('Authorization')! },
        },
      }
    );

    const url = new URL(req.url);
    const prefeituraId = url.searchParams.get('prefeitura_id');

    if (!prefeituraId) {
      return new Response(
        JSON.stringify({ error: 'prefeitura_id é obrigatório' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Buscar estatísticas gerais
    const { data: stats, error: statsError } = await supabaseClient
      .from('ocorrencias')
      .select('status, created_at')
      .eq('prefeitura_id', prefeituraId);

    if (statsError) {
      throw statsError;
    }

    // Calcular estatísticas
    const total = stats.length;
    const recebidas = stats.filter(o => o.status === 'recebido').length;
    const em_analise = stats.filter(o => o.status === 'em_analise').length;
    const em_atendimento = stats.filter(o => o.status === 'em_atendimento').length;
    const resolvidas = stats.filter(o => o.status === 'resolvido').length;
    const rejeitadas = stats.filter(o => o.status === 'rejeitado').length;

    // Ocorrências por dia (últimos 30 dias)
    const thirtyDaysAgo = new Date();
    thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);

    const recentStats = stats.filter(o => 
      new Date(o.created_at) >= thirtyDaysAgo
    );

    // Agrupar por dia
    const dailyStats = {};
    recentStats.forEach(o => {
      const date = new Date(o.created_at).toISOString().split('T')[0];
      if (!dailyStats[date]) {
        dailyStats[date] = { date, total: 0, resolvidas: 0 };
      }
      dailyStats[date].total++;
      if (o.status === 'resolvido') {
        dailyStats[date].resolvidas++;
      }
    });

    return new Response(
      JSON.stringify({
        success: true,
        data: {
          estatisticas_gerais: {
            total,
            recebidas,
            em_analise,
            em_atendimento,
            resolvidas,
            rejeitadas,
            percentual_resolucao: total > 0 ? Math.round((resolvidas * 100) / total) : 0
          },
          estatisticas_diarias: Object.values(dailyStats),
          periodo_dias: 30
        }
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('Erro:', error);
    return new Response(
      JSON.stringify({ 
        error: 'Erro interno do servidor',
        details: error.message 
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});