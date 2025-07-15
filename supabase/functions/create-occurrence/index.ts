import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Configurações para permitir requisições do app
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  // Se for uma verificação de CORS, responde OK
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // Conecta com o banco de dados
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      {
        global: {
          headers: { Authorization: req.headers.get('Authorization')! },
        },
      }
    );

    // Verifica se o usuário está logado
    const { data: { user }, error: authError } = await supabaseClient.auth.getUser();

    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: 'Usuário não está logado' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Pega os dados enviados pelo app
    const occurrenceData = await req.json();

    // Validação simples
    if (!occurrenceData.titulo || !occurrenceData.descricao) {
      return new Response(
        JSON.stringify({ error: 'Título e descrição são obrigatórios' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Pega a prefeitura (por enquanto fixo em Jaú)
    const { data: prefeitura } = await supabaseClient
      .from('prefeituras')
      .select('id')
      .eq('cidade', 'Jaú')
      .eq('estado', 'SP')
      .single();

    if (!prefeitura) {
      return new Response(
        JSON.stringify({ error: 'Prefeitura não encontrada' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Cria a ocorrência no banco
    const { data: ocorrencia, error: insertError } = await supabaseClient
      .from('ocorrencias')
      .insert({
        user_id: user.id,
        prefeitura_id: prefeitura.id,
        titulo: occurrenceData.titulo,
        descricao: occurrenceData.descricao,
        categoria_id: occurrenceData.categoria_id,
        latitude: occurrenceData.latitude,
        longitude: occurrenceData.longitude,
        endereco: occurrenceData.endereco,
        fotos: occurrenceData.fotos || [],
        videos: occurrenceData.videos || [],
      })
      .select('*')
      .single();

    if (insertError) {
      throw insertError;
    }

    // Retorna sucesso
    return new Response(
      JSON.stringify({ 
        success: true, 
        data: ocorrencia,
        message: 'Ocorrência criada com sucesso!'
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